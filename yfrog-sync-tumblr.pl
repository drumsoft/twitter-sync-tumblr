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
	yfrog_hashdump => '.dump.' . __FILE__,
	tumblr_oauth => {
		site               => q{http://www.tumblr.com},
		request_token_path => q{/oauth/request_token},
		access_token_path  => q{/oauth/access_token},
		authorize_path     => q{/oauth/authorize},
	},
);

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

if ( $ARGV[0] && $ARGV[0] =~ /^conf/i ) {
	Config::Pit::set("yfrog.com", config => $pit_yfrog);
	Config::Pit::set("www.tumblr.com", config => $pit_tumblr);
}

main();

# ---------------------------------------------------------------
sub main {
	my $tumblr_consumer = tumblr_oauth_getconsumer($pit_tumblr);
	if ( ! tumblr_oauth_testconsumer( $pit_tumblr, $tumblr_consumer ) ) {
		tumblr_oauth_authenticate( $pit_tumblr );
	}

	my $yfrog_hashes = hash_from_dump();
	my $photos = get_yfrog_photos($pit_yfrog, $yfrog_hashes);
	print @$photos . " photos marked to upload.\n";

	foreach ( reverse @$photos ) {
		if ( $_->{photo_link} =~ m|/([^/]+)$| ) {
			print "upload: $_->{photo_link}\n";
			my $hash = $1;
			my $info = get_yfrog_photoinfo($pit_yfrog, $hash);
			if ( ! defined $info ) {
				$info = { 
					message => '', 
					created_time => get_yfrog_photocreatedtime($_->{photo_link}) 
				};
			}
			my $url  = get_yfrog_fullsizeimageurl($hash);
			
			post_tumblr( $pit_tumblr, $tumblr_consumer, {
				type => 'photo',
				tags => $pit_tumblr->{tags},
				date => tumblr_datetime( $info->{created_time} ),
				slug => $pit_tumblr->{slug_prefix} . $hash,
				source => $url,
				caption => $info->{message},
			});
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
		print "loading yfrog page $page.\n";
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
	my $res = $imagescraper->scrape( URI->new('http://yfrog.com/z/' . $hash) );

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
				print "'Error uploading photo.' for $param->{slug}. the error ignored.\n";
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

	print "\nTumblr oAuth process start.\n\n";

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
	print "1. access this URL with your browser and authorize.\n";
	print "  $url\n\n";

	print "2. input url your browser be redirected to.\n";
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

	print "\naccess token saved. Tumblr oAuth process completed.\n\n";
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



# --------------------------------------------------------------
__END__

# 使い方

1. 準備


1-1. yfrog の API Key を取得する
http://stream.imageshack.us/api/
に必要事項を入力して、 yfrog API key を取得します。

Email より後の項目は（適当でもいいのですが）以下の様に入力します。
- Will you use Twitter...?: Yes, ...
- Web Site: 自分のサイトのURL または http://localhost/
- Which of these best describes...: Desktop App
- Which best describes...: Personal
- How many people use...: 0-99
- Describe your implementation: Sync yfrog and Tumblr
- How many API keys: 1

登録すると API Key が表示されます（メールでも届きます）
これは以降 yfrog の devkey と呼ばれます。


1-2. Tumblr の Consumer Key を取得する
http://www.tumblr.com/oauth/apps
で アプリケーションを登録 というボタンから以下を登録します
- Application name: yfrog-sync-tumblr
- Application website: 自分のサイトのURL または http://localhost/
- Application description: Sync yfrog and Tumblr
- Administrative contact email: 自分のメアド
- Default callback URL: http://localhost/
- Icon: 登録しなくてOK

登録すると OAuth Consumer Key: が表示されます。
Show Secret Key をクリックすると Secret Key も表示されます。
この2つをメモります。

これは以降 Tumblr の consumer_key と consumer_secret と呼ばれます。


1-3. EDITOR 環境変数を登録する

EDITOR 環境変数が未設定の場合、これを設定します。
env | grep EDITOR
というコマンドで確認できます。

設定は以下の様なコマンドで、好きなエディタを設定します。
export EDITOR=emacs
export EDITOR=vi

（環境変数を恒久的に設定したい場合は .profile 等に上記コマンドを書く必要があります。詳しくはWebで）


1-4. 設定を書き込む

コマンドラインで perl yfrog-sync-tumblr.pl と入力してこのスクリプトを起動します。

初回起動時の場合は、自動的に EDITOR に設定したエディタで設定ファイルが開かれる。まず yfrog の設定ファイルが開かれるので、
- 自分の yfrog ユーザ名
- yfrog の devkey
をファイルに書き（シングルクォートは消さずにその中に書く）、
保存してエディタを終了します。

次に Tumblr の設定ファイルが開かれるので、
- 自分の Tumblr ホスト名（MYNAME.tumblr.com みたいなやつ）
- アップした写真につけたいタグ
- slugのprefix(※)
- Tumblr の consumer_key
- Tumblr の consumer_secret
をファイルに書き、保存してエディタを終了します。

※各ポストのURL末尾につけられる記号を slug と呼びます。 yfrog-sync-tumblr は、任意のprefixとyfrogの HASH (yfrogのURL末尾の、写真を一意に識別する為の記号) をくっつけたものを slug として指定します。ここで、その prefix を指定して下さい。分からなければ 'yfrog_' がオススメです。

1度設定すると、次回以降の起動では設定ファイルは開かれません。後から設定をやり直したい場合、 perl yfrog-sync-tumblr.pl conf と 引数に conf を指定して起動して下さい。設定は ~/.pit/default.yaml に保存されています。


1-5. Tumblr の oAuth 認証を行う

初回起動時と Tumblr の oAuth 認証失敗時には、 oAuth 認証プロセスが始まります。
コマンドラインに表示される URL をコピーして、ブラウザで開き、認証ボタンを押して下さい。
こんどはリダイレクトされた先のURLをコピーし、コマンドラインに入力して下さい。

以上で認証が完了します。認証の結果は、 1-4 の Tumblr 設定ファイルに保存されています。他のアカウントで使いたい場合等、認証をやり直したい場合は、 perl yfrog-sync-tumblr.pl conf を起動して Tumblr 設定ファイルから "access_token" : ... という行を削除して下さい。

認証プロセスの終了後は、スクリプトは何もせずに終了する様になっています。
これで準備は終了です。


2 使い方

2-1. スクリプトを起動する

コマンドラインで perl yfrog-sync-tumblr.pl と入力してこのスクリプトを起動します。
yfrog のページを先頭から順（新しい物順）に読み込みを開始し、最後のページまで読み込むか、既にアップロードした写真に到達したら読み込みを終了します。

読み込みが終了したら、写真を古い順に Tumblr にアップロードしはじめます。

最初は何もアップロードしていないので、 yfrog の全ての写真が Tumblr にアップロードされます。
おそらく、1日のアップロード枚数制限(80枚くらい)にひっかかって、途中でエラー終了すると思います。翌日以降にまたチャレンジしましょう。

2回目以降は、前回までにアップロード完了した写真以降がアップロードされます。


3. アップロード済みの写真を管理する

どの写真をアップロードしたかの記録は、 .dump.yfrog-sync-tumblr.pl というファイルに保存されています。このファイルの中にある
  'SOMEHASH' => 1,
という記述は、 yfrog の http://yfrog.com/SOMEHASH というファイルをアップロードした事を示しています。

全ての写真をアップロードしなおすには: 
	.dump.yfrog-sync-tumblr.pl を削除して下さい。

アップロードをある写真以降の新しい物だけにしたい場合は:
	アップしたい写真の「次に古い写真」の hash （ http://yfrog.com/SOMEHASH の SOMEHASH の部分）を調べ
  'SOMEHASH' => 1,
という行を .dump.yfrog-sync-tumblr.pl に追加します。


4. 自動化する

perl yfrog-sync-tumblr.pl の実行を自動化すれば、今後 yfrog にアップした写真を自動的に Tumblr に反映させる事ができます。
Mac の場合は launchd, Linux は crontab, Windows は タスク, で検索して設定してみて下さい。


