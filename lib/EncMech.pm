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
    $DBH = DBI->connect("dbi:sqlite:dbname=encmech.db", "", "", {
        RaiseError => 1,
        AutoCommit => 1,
    }) or die $DBI::errstr;
    return $DBH;
}

sub retrieve {
    my ($q) = @_;

    my $dbh = db();

    my $result = $dbh->selectrow_arrayref(qq{SELECT content FROM pages WHERE query=?},
        {Slice => {}}, $q);
    return $result->{content} if $result;

    my $content = generate($q);
    $dbh->do(qq{INSERT INTO paegs (query, content) VALUES (?, ?)}, undef, $q, $content);
    return $content;
}

sub generate {
    my ($q) = @_;

    -f 'key' or die "Please put your OpenAI API key in a file called 'key'";
    my $key = read_file("key");
    my $system = read_file("prompt");
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
    return $r->{choices}[0]{message}{content};

}

1;
