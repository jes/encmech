package EncMech;

use strict;
use warnings;

use DBI;
use DBD::SQLite;
use File::Slurp qw(read_file);
use LWP::UserAgent;
use JSON qw(encode_json decode_json);
use Try::Tiny;
use IO::Pipe;
use POSIX ":sys_wait_h";
use AnyEvent;
use AnyEvent::Handle;

my $ua = LWP::UserAgent->new;
my $CONTENT = '';
my $PIPE_HANDLE;
my $PIPE;
my $DBH;

sub db {
    return $DBH if $DBH && $DBH->ping;
    $DBH = DBI->connect("dbi:SQLite:dbname=encmech.db", "", "", {
        RaiseError => 1,
        AutoCommit => 1,
    }) or die $DBI::errstr;
    $DBH->do(qq{CREATE TABLE IF NOT EXISTS pages (query TEXT PRIMARY KEY, content TEXT, created TIMESTAMP)});
    return $DBH;
}

sub retrieve {
    my ($q, $cb) = @_;

    my $dbh = db();

    my $result = $dbh->selectrow_arrayref(qq{SELECT content FROM pages WHERE query=?},
        {Slice => {}}, $q);
    return $cb->($result->[0], 1) if $result;

    my $last_call_time = 0;
    generate($q, sub {
        my ($chunk, $finished) = @_;
        $dbh->do(qq{INSERT INTO pages (query, content, created) VALUES (?, ?, CURRENT_TIMESTAMP)}, undef, $q, $chunk) if $finished;
        my $current_time = Time::HiRes::time();
        if ($current_time - $last_call_time >= 0.1 || $finished) {
            $cb->($chunk, $finished);
            $last_call_time = $current_time;
        }
    });
}

sub generate {
    my ($q, $cb) = @_;
    $CONTENT = '';

    my $key = read_file("key");
    chomp $key;
    my $system = read_file("prompt");
    my $system2 = read_file("prompt2");
    $system =~ s/__TOPIC__/$q/g;
    my $model = "gpt-4o-mini";

    $PIPE = IO::Pipe->new();
    my $pid = fork();

    if ($pid == 0) {
        # Child process
        $PIPE->writer();
        
        # First request
        make_api_request($PIPE, $key, $model, [
            { role => 'system', content => $system },
        ]);

        # Second request
        make_api_request($PIPE, $key, $model, [
            { role => 'system', content => $system },
            { role => 'assistant', content => $CONTENT },
            { role => 'system', content => $system2 },
        ]);

        $PIPE->print(encode_json({content => $CONTENT}) . "\n");
        $PIPE->close();
        exit 0;
    } else {
        # Parent process
        setup_pipe_reader($PIPE, $cb);
    }
}

sub make_api_request {
    my ($pipe, $key, $model, $messages) = @_;
    my $body = {
        model => $model,
        messages => $messages,
        stream => JSON::true,
    };

    my $buf = '';
    $CONTENT = '';

    my $response = $ua->post(
        "https://api.openai.com/v1/chat/completions",
        'Content-Type' => 'application/json',
        'Authorization' => "Bearer $key",
        Content => encode_json($body),
        ':content_cb' => sub {
            my ($chunk, $res, $proto) = @_;
            $buf .= $chunk;
            while ($buf =~ s/^data: (.+?)\n\n//s) {
                my $data = $1;
                if ($data eq '[DONE]') {
                    last;
                }
                try {
                    my $decoded_chunk = decode_json($data);
                    if ($decoded_chunk->{choices}[0]{delta}{content}) {
                        $CONTENT .= $decoded_chunk->{choices}[0]{delta}{content};
                        $pipe->print(encode_json({content => $CONTENT}) . "\n");
                        $pipe->flush();
                    }
                } catch {
                    warn "Error decoding JSON: $_";
                }
            }
        },
    );
}

sub setup_pipe_reader {
    my ($pipe, $cb) = @_;
    $pipe->reader();

    my $content = '';
    
    $PIPE_HANDLE = AnyEvent::Handle->new(
        fh => $pipe,
        on_read => sub {
            my ($handle) = @_;
            $handle->push_read(line => sub {
                my ($handle, $line, $eol) = @_;
                chomp $line;
                $content = decode_json($line)->{content};
                $cb->($content, 0);
            });
        },
        on_error => sub {
            my ($handle, $fatal, $msg) = @_;
            warn "Error reading from pipe: $msg";
            undef $PIPE_HANDLE;  # Clean up the handle
        },
        on_eof => sub {
            undef $PIPE_HANDLE;  # Clean up the handle
            $cb->($content, 1);
        },
    );
}

1;
