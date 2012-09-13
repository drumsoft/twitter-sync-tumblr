#!/usr/bin/perl

use strict;
use warnings;

use utf8;
use Encode qw/encode decode/;

use LWP::UserAgent;
use CGI::Util;
use Config::Pit;
use URI;
use Web::Scraper;
use Data::Dumper;
use JSON;
use YAML;
use OAuth::Lite::Consumer;
use Getopt::Long;
use File::Basename;

{
	no warnings 'redefine';
	*OAuth::Lite::Util::encode_param = sub {
	    my $param = shift;
	    URI::Escape::uri_escape_utf8($param, '^\w.~-');
	};
}

# global settings
my %preference = (
	yfrog_pagesize => 25,
	yfrog_hashdump => '.dump.yfrog-sync-tumblr.pl',
	tumblr_oauth => {
		site               => q{http://www.tumblr.com},
		request_token_path => q{/oauth/request_token},
		access_token_path  => q{/oauth/access_token},
		authorize_path     => q{/oauth/authorize},
	},
);

# global
my $quiet = 0;

# get keys from Pit
my $pit_yfrog = pit_get("yfrog.com", require => {
	screen_name => 'your screen name on yfrog.com',
	devkey      => 'your devkey on yfrog.com',
});
my $pit_tumblr = pit_get("www.tumblr.com", require => {
	host_name   => 'your tumblr\'s host name (ex. "MYNAME.tumblr.com")',
	tags        => 'tags appended to each posts.(ex. "yfrog")',
	slug_prefix => 'slug for each posts will be PREFIX<hash_of_yfrog> (ex. "yfrog_")',
	consumer_key    => 'tumblr oAuth consumer key',
	consumer_secret => 'tumblr oAuth consumer secret',
});

# ---------------------------------------------------------------
sub say($) {
	my $text = shift;
	if ( ! $quiet ) {
		printf STDOUT "%s\n", $text;
	}
	return $text;
}
sub sayerror($) {
	my $text = shift;
	my ($pkg, $file, $line) = caller;
	$file = basename($file);
	printf STDERR "[%s error] %s in line %d\n", $file, $text, $line;
	return $text;
}

# ---------------------------------------------------------------
main();
sub main {
	# re-config
	my $config;
	GetOptions('config' => \$config, 'quiet' => \$quiet);
	if ( $config ) {
		die 'EDITOR is not set. try "export EDITOR=emacs" or what you like.' if ! defined $ENV{EDITOR} || ! $ENV{EDITOR};
		die 'config is not editable while quiet mode.' if $quiet;
		Config::Pit::set("yfrog.com", config => $pit_yfrog);
		Config::Pit::set("www.tumblr.com", config => $pit_tumblr);
	}

	# get Tumblr consumer and test it.
	my $tumblr_consumer = tumblr_oauth_getconsumer($pit_tumblr);
	if ( ! tumblr_oauth_testconsumer( $pit_tumblr, $tumblr_consumer ) ) {
		die 'Tumblr oAuth required.' if $quiet;
		tumblr_oauth_authenticate( $pit_tumblr );
	}

	# get yfrog processed hashes
	my $yfrog_hashes = hash_from_dump();

	my $photos;
	if ( @ARGV ) {
		# prepare yfrog photo hashes from argv.
		$photos = [reverse map { {
			photo_link => ($_ =~ /^https?:/ ? '' : 'http://yfrog.com/') . $_
		} } @ARGV];
	} else {
		# get new yfrog photo hashes from yfrog web.
		$photos = get_yfrog_photos($pit_yfrog, $yfrog_hashes);
	}
	say (@$photos . " photos marked to upload.");

	foreach ( reverse @$photos ) {
		if ( $_->{photo_link} =~ m|/([^/]+)$| ) {
			say "upload: $_->{photo_link}";
			my $hash = $1;
			my $info = get_yfrog_photoinfo($pit_yfrog, $hash);
			if ( ! defined $info ) {
				$info = { 
					message => '', 
					created_time => get_yfrog_photocreatedtime($_->{photo_link}) 
				};
			}
			my $url  = get_yfrog_fullsizeimageurl($hash);
			
			post_tumblr( $pit_tumblr, $tumblr_consumer, 
#			print YAML::Dump(
			{
				type => 'photo',
				tags => $pit_tumblr->{tags},
				date => tumblr_datetime( $info->{created_time} ),
				slug => $pit_tumblr->{slug_prefix} . $hash,
				source => $url,
				caption => $info->{message},
			}, $_->{photo_link});
			$yfrog_hashes->{$hash} = 1;
			hash_to_dump( $yfrog_hashes );
		}
	}
}




# ----------------------------------------------------------------- yfrog
sub get_yfrog_photos {
	my $yfrog = shift;
	my $hash = shift;
	my @photos;
	my $page = 1;
	
	while (1) {
		my $url = sprintf 
			'http://yfrog.com/api/userphotos.json?limit=%d&page=%d&screen_name=%s&devkey=%s', 
			$preference{yfrog_pagesize}, $page, $yfrog->{screen_name}, $yfrog->{devkey};
		say "loading yfrog page $page.";
		my $result = http_get_json( $url );
		if ( ! $result->{success} ) {
			die 'yfrog photos retrive error:' . YAML::Dump($result);
		}
		if ( @{ $result->{result}->{photos} } == 0 ) {
			return \@photos; # got all photos
		}
		# processed file check
		foreach ( @{ $result->{result}->{photos} } ) {
			if ( $_->{photo_link} =~ m|/([^/]+)$| && exists $hash->{ $1 } ) {
				return \@photos; # find a photo already processed.
			}
			push @photos, $_;
		}
		$page++;
	}
	return \@photos; # photo_link
}

sub get_yfrog_photoinfo {
	my $yfrog = shift;
	my $hash = shift;
	my @photos;
	
	my $url = sprintf 
		'http://yfrog.com/api/photoinfo.json?url=%s&devkey=%s', 
		$hash, $yfrog->{devkey};
	my $result;
	eval {
		$result = http_get_json( $url );
	};
	if ( $@ ) {
		if ( $@ =~ /500/ ) {
			return undef;
		}
		die 'get_yfrog_photoinfo failed: $@';
	}
	if ( ! $result->{success} ) {
		die 'get_yfrog_photoinfo failed:' . YAML::Dump($result);
	}
	return $result->{result}->{photo_info}->[0]; # created_time, message
}

# get created_time when photoinfo API returns error.
# 1. get standard photo page.
# 2. scrape  /setCreatedTime\(\d+\)/. matched number is created_date.
sub get_yfrog_photocreatedtime {
	my $url = shift;
	my $ua = LWP::UserAgent->new();
	my $response = $ua->get($url);
	if ( ! $response->is_success ) {
		die "get_yfrog_photocreatedtime failed: " . YAML::Dump($response);
	}
	if ( $response->content =~ /setCreatedTime\((\d+)\)/ ) {
		return $1;
	} else {
		die "get_yfrog_photocreatedtime time not found: " . $response->content;
	}
}

# yfrog full size image url is not available via API
# 1. get full size photo page's html from http://yfrog.com/z/HASH
# 2. scrape the "src" attribute from the element selected with "div#the-image img";
sub get_yfrog_fullsizeimageurl {
	my $hash = shift;

	my $imagescraper = scraper {
		process "#the-image img", "url" => '@src'
	};
	my $res = $imagescraper->scrape( URI->new('http://twitter.yfrog.com/z/' . $hash) );

	$res->{url}->as_string;
}



# ----------------------------------------------------------------- Tumblr
sub tumblr_datetime {
	my $dt = shift;
	my ($s, $mi, $h, $d, $mo, $y) = gmtime($dt);
	sprintf '%04d-%02d-%02d %02d:%02d:%02d GMT', $y+1900, $mo+1, $d, $h, $mi, $s;
}

sub post_tumblr {
	my $tumblr = shift;
	my $consumer = shift;
	my $param = shift;
	my $yfrog_url = shift;

	my $res = $consumer->request(
		method => 'POST',
		url    => sprintf('http://api.tumblr.com/v2/blog/%s/post', $tumblr->{host_name}),
		params => $param,
	);

	if ( $res->code != 201 ) {
		my $ignore = 0;
		eval {
			my $json = decode_json( $res->decoded_content() );
			if (grep 'Error uploading photo.', @{ $json->{response}->{errors} }) {
				sayerror "'Error uploading photo.' for $yfrog_url. the error ignored.";
				$ignore = 1;
			}
		};
		return if $ignore;
		die "tumblr post failed: " . YAML::Dump($res) . YAML::Dump($res->decoded_content());
	}
}



# --------------------------------------------------------- Utility
sub http_get_json {
	my $url = shift;
	my $ua = LWP::UserAgent->new();
	my $response = $ua->get($url);
	if ( ! $response->is_success ) {
		die "http_get_json failed: " . $response->status_line;
	}
	decode_json( $response->content );
}

# -------------------------------------------------------- Tumblr oAuth 
sub tumblr_oauth_getconsumer {
	my $tumblr = shift;

	if ( ! exists $tumblr->{access_token} || ! defined $tumblr->{access_token} ) {
		return undef;
	}

	my $consumer = OAuth::Lite::Consumer->new(
		consumer_key    => $tumblr->{consumer_key},
		consumer_secret => $tumblr->{consumer_secret},
	);

	my $access_token = OAuth::Lite::Token->from_encoded( $tumblr->{access_token} );
	$consumer->access_token($access_token);

	$consumer;
}

sub tumblr_oauth_testconsumer {
	my $tumblr = shift;
	my $consumer = shift;

	if ( ! defined $consumer ) {
		return 0;
	}

	my $res = $consumer->request(
		method => 'GET',
		url    => sprintf('http://api.tumblr.com/v2/blog/%s/followers', $tumblr->{host_name}),
		params => { limit => 0 },
	);

	unless ($res->is_success) {
		if ($res->status == 400 || $res->status == 401) {
			my $auth_header = $res->header('WWW-Authenticate');
			if ($auth_header && $auth_header =~ /^OAuth/) {
				return 0;
			} else {
				die 'Tumblr oAuth auth error' . YAML::Dump($res);
			}
		}
		die 'Tumblr oAuth access error' . YAML::Dump($res);
	}
	return 1;
}

sub tumblr_oauth_authenticate {
	my $tumblr = shift;

	say "\nTumblr oAuth process start.\n";

	my $consumer = OAuth::Lite::Consumer->new(
		consumer_key    => $tumblr->{consumer_key},
		consumer_secret => $tumblr->{consumer_secret},
		%{ $preference{tumblr_oauth} }
	);

	my $request_token = $consumer->get_request_token(
		callback_url => 'http://localhost/tumblr/',
	);

	my $url = $consumer->url_to_authorize(
		token => $request_token,
	);
	say "1. access this URL with your browser and authorize.";
	say "  $url\n";

	say "2. input url your browser be redirected to.";
	my $redirected = <STDIN>;
	chomp $redirected;
	my %redirected_param = map { 
		my @p = split /=/, $_, 2;
		$p[0] => CGI::Util::unescape($p[1])
	} split /&/, (split /\?/, $redirected, 2)[1];

	my $access_token = $consumer->get_access_token(
		token    => $request_token,
		verifier => $redirected_param{oauth_verifier},
	);

	$tumblr->{access_token} = $access_token->as_encoded;
	Config::Pit::set("www.tumblr.com", data => $tumblr);

	say "\naccess token saved. Tumblr oAuth process completed.\n";
	exit(0);
}



# --------------------------------------------------- store processed yfrog hash
sub hash_from_dump {
	if ( -e $preference{yfrog_hashdump} ) {
		my $VAR1;
		local $/ = undef;
		open my $in, '<', $preference{yfrog_hashdump} or die 'cannot read hashdump';
		eval <$in>;
		close $in;
		$VAR1;
	} else {
		{};
	}
}
sub hash_to_dump {
	my $hash = shift;
	open my $fh, '>', $preference{yfrog_hashdump} or die 'cannot write hashdump';
	print $fh Dumper($hash);
	print $fh "\n1;\n";
	close $fh;
}

