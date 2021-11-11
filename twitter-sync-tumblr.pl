#!/usr/bin/perl

use strict;
use warnings;

use utf8;
use Encode qw/encode decode/;

use Net::Twitter;
use CGI::Util;
use Config::Pit;
use URI;
use JSON;
use YAML;
use OAuth::Lite::Consumer;
use Getopt::Long;
use DateTime::Format::DateParse;
use Math::BigInt;

{
	no warnings 'redefine';
	*OAuth::Lite::Util::encode_param = sub {
	    my $param = shift;
	    URI::Escape::uri_escape_utf8($param, '^\w.~-');
	};
}

# global settings
my %preference = (
	twitter_lastid_file => '.lastid.twitter-sync-tumblr.pl',
	twitter_pagesize => 200,
	twitter_pageslimit => 20,
	tumblr_oauth => {
		site               => q{https://www.tumblr.com},
		request_token_path => q{/oauth/request_token},
		access_token_path  => q{/oauth/access_token},
		authorize_path     => q{/oauth/authorize},
	},
);

# global
my $quiet = 0;

# get keys from Pit
my $pit_twitter = pit_get("twitter.com", require => {
	screen_name         => 'your screen name on Twitter',
	consumer_key        => 'Consumer key for the Twitter app you created on https://dev.twitter.com/apps',
	consumer_secret     => 'Consumer secret for the app.',
	access_token        => 'Your access token created in the app detail page.',
	access_token_secret => 'Your access token secret.',
});
my $pit_tumblr = pit_get("www.tumblr.com", require => {
	host_name   => 'your tumblr\'s host name (ex. "MYNAME.tumblr.com")',
	tags        => 'tags appended to each posts.(ex. "twitter")',
	slug_prefix => 'slug for each posts will be PREFIX<id_of_tweet> (ex. "twitter_")',
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
		Config::Pit::set("twitter.com", config => $pit_twitter);
		Config::Pit::set("www.tumblr.com", config => $pit_tumblr);
	}

	# get Tumblr consumer and test it.
	my $tumblr_consumer = tumblr_oauth_getconsumer($pit_tumblr);
	if ( ! tumblr_oauth_testconsumer( $pit_tumblr, $tumblr_consumer ) ) {
		die 'Tumblr oAuth required.' if $quiet;
		tumblr_oauth_authenticate( $pit_tumblr );
	}

	# get twitter processed lastid
	my $twitter_lastid = lastid_restore();

	my $medias;
	if ( @ARGV ) {
		# prepare twitter medias from argv.
		$medias = [map { get_twitter_media_id($_) }  @ARGV];
	} else {
		# get new media from twitter
		$medias = get_twitter_media($twitter_lastid);
	}
	say (@$medias . " medias marked to upload.");
	@$medias = sort { compare_id_str($a->{id_str}, $b->{id_str}) } @$medias;

	foreach ( @$medias ) {
		say "upload: $_->{tweet_url}";
		post_tumblr( $pit_tumblr, $tumblr_consumer, $_->{tweet_url}, 
#		print YAML::Dump(
		{
			type => $_->{type},
			tags => $pit_tumblr->{tags},
			date => tumblr_datetime( $_->{created_at} ),
			slug => $pit_tumblr->{slug_prefix} . $_->{id_str},
			source => $_->{media_url},
			caption => $_->{text},
		});
		if ( compare_id_str( $_->{id_str}, $twitter_lastid ) > 0 ) {
			$twitter_lastid = $_->{id_str};
			lastid_store( $twitter_lastid );
		}
	}
}


# ----------------------------------------------------------------- twitter
sub compare_id_str {
	my $a = shift;
	my $b = shift;
	my $length_cmp = length($a) <=> length($b);
	return ($length_cmp == 0) ? ($a cmp $b) : $length_cmp;
}

sub decrement_id_str {
	my $b_max_id = Math::BigInt->new(shift);
	$b_max_id->bdec();
	return $b_max_id->bstr();
}

my $parse_time_parser;
sub parse_time {
	my $ctime = shift;
	my $dt = DateTime::Format::DateParse->parse_datetime($ctime);
	return $dt->epoch();
}

sub extract_medias_from_tweet {
	my $tw = shift;
	my @medias;
	if ( exists $tw->{entities} && exists $tw->{entities}->{media} ) {
		foreach my $md ( @{ $tw->{entities}->{media} } ) {
			if ( 'photo' eq $md->{type} ) {
				push @medias, {
					id_str      => $tw->{id_str},
					type        => $md->{type},
					media_url   => $md->{media_url} . ':large', 
					text        => $tw->{text}, 
					created_at  => parse_time($tw->{created_at}), #Mon Jun 24 22:52:38 +0000 2013
					screen_name => $pit_twitter->{screen_name},
					tweet_url   => 'https://twitter.com/' . $pit_twitter->{screen_name} . '/status/' . $tw->{id_str},
				};
			} else {
				say 'unknown media type' . $md->{type};
				say YAML::Dump($md);
			}
		}
	}
	return @medias;
}

my $net_twitter_instance;
sub get_net_twitter {
	if ( ! defined $net_twitter_instance ) {
		$net_twitter_instance = Net::Twitter->new(
			traits   => [qw/OAuth API::RESTv1_1/], 
			ssl      => 1, 
			consumer_key        => $pit_twitter->{consumer_key}, 
			consumer_secret     => $pit_twitter->{consumer_secret}, 
			access_token        => $pit_twitter->{access_token}, 
			access_token_secret => $pit_twitter->{access_token_secret}, 
		);
	}
	return $net_twitter_instance;
}

sub get_twitter_media_id {
	my $id_str = shift;

	say "loading twitter status $id_str.";
	my $r = get_net_twitter()->show_status({
		id => $id_str, 
		trim_user => 1, 
		include_entities => 1,
	});

	if ( ! ref($r) ) {
		die 'twitter tweet retrive error:' . YAML::Dump($r);
	}

	# say YAML::Dump($r);
	return extract_medias_from_tweet($r);
}

sub get_twitter_media {
	my $lastid = shift;
	my @medias;
	my $pages_read = 0;
	my $max_id;

	while (1) {
		say "loading twitter page: $pages_read, max_id: " . (defined $max_id ? $max_id : 'null');
		my $args = {
			screen_name => $pit_twitter->{screen_name}, 
			count => $preference{twitter_pagesize}, 
			trim_user => 1, 
			include_rts => 'false', 
		};
		$args->{max_id} = $max_id if defined $max_id;
		my $r = get_net_twitter()->user_timeline($args);

		if ( ! ref($r) ) {
			die 'twitter tweet retrive error:' . YAML::Dump($r);
		}
		if ( @{ $r } == 0 ) {
			last; # got all tweets
		}
		# process each tweets
		my $last_found = 0;
		foreach my $tw ( @{ $r } ) {
			if ( compare_id_str($tw->{id_str}, $lastid) <= 0 ) {
				$last_found = 1;
				last; # lastid found.
			}
			push @medias, extract_medias_from_tweet($tw);
		}

		# set max_id for next page load
		$max_id = decrement_id_str($r->[-1]->{id_str});

		$pages_read++;
		if ( $last_found || $pages_read >= $preference{twitter_pageslimit} ) {
			last; # lastid found or read pages to limit
		}
	}
	return \@medias;
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
	my $twitter_url = shift;
	my $param = shift;

	my $res = $consumer->request(
		method => 'POST',
		url    => sprintf('https://api.tumblr.com/v2/blog/%s/post', $tumblr->{host_name}),
		params => $param,
	);

	if ( $res->code != 201 ) {
		my $ignore = 0;
		eval {
			my $json = decode_json( $res->decoded_content() );
			if (grep 'Error uploading photo.', @{ $json->{response}->{errors} }) {
				sayerror "'Error uploading photo.' for $twitter_url. the error ignored.";
				$ignore = 1;
			}
		};
		return if $ignore;
		die "tumblr post failed: " . YAML::Dump($res) . YAML::Dump($res->decoded_content());
	}
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
		url    => sprintf('https://api.tumblr.com/v2/blog/%s/followers', $tumblr->{host_name}),
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



# --------------------------------------------------- store processed twitter id
sub lastid_restore {
	if ( ! -e $preference{twitter_lastid_file} ) {
		return 0;
	}
	open my $in, '<', $preference{twitter_lastid_file} or die 'cannot read lastid';
	chomp(my $lastid = <$in>);
	close $in;
	return $lastid;
}
sub lastid_store {
	my $lastid = shift;
	open my $fh, '>', $preference{twitter_lastid_file} or die 'cannot write lastid';
	print $fh $lastid;
	close $fh;
}

