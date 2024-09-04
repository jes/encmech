package EncMech;

use strict;
use warnings;

use DBI;
use DBD::SQLite;
use File::Slurp qw(read_file);
use LWP::UserAgent;
use JSON qw(encode_json decode_json);

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
    my ($q) = @_;

    my $dbh = db();

    my $result = $dbh->selectrow_arrayref(qq{SELECT content FROM pages WHERE query=?},
        {Slice => {}}, $q);
    return $result->[0] if $result;

    my $content = generate($q);
    $dbh->do(qq{INSERT INTO pages (query, content, created) VALUES (?, ?, CURRENT_TIMESTAMP)}, undef, $q, $content);
    return $content;
}

sub generate {
    my ($q) = @_;

    -f 'key' or die "Please put your OpenAI API key in a file called 'key'";
    my $key = read_file("key");
    my $system = read_file("prompt");
    my $system2 = read_file("prompt2");
    $system =~ s/__TOPIC__/$q/g;
    my $model = "gpt-4o-mini";

    my $body = {
        model => $model,
        messages => [
            {
                role => 'system',
                content => $system,
            },
        ],
    };

    my $ua = LWP::UserAgent->new;
    my $r = $ua->post("https://api.openai.com/v1/chat/completions",
        Authorization => "Bearer $key",
        'Content-Type' => 'application/json',
        Content => encode_json($body)
    );
    print STDERR $r->decoded_content;
    $r = decode_json($r->decoded_content);
    my $draft = $r->{choices}[0]{message}{content};

    $body = {
        model => $model,
        messages => [
            {
                role => 'system',
                content => $system,
            },
            {
                role => 'assistant',
                content => $draft,
            },
            {
                role => 'system',
                content => $system2,
            },
        ],
    };

    $r = $ua->post("https://api.openai.com/v1/chat/completions",
        Authorization => "Bearer $key",
        'Content-Type' => 'application/json',
        Content => encode_json($body)
    );
    print STDERR $r->decoded_content;
    $r = decode_json($r->decoded_content);
    return $r->{choices}[0]{message}{content};
}

1;
