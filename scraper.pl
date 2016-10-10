#!/usr/bin/env perl
# Copyright 2014 Michal Špaček <tupinek@gmail.com>

# Pragmas.
use strict;
use warnings;

# Modules.
use Database::DumpTruck;
use Digest::MD5;
use Encode qw(decode_utf8 encode_utf8);
use English;
use File::Temp qw(tempfile);
use HTML::TreeBuilder;
use LWP::UserAgent;
use POSIX qw(strftime);
use URI;
use Time::Local;
use Date::Calc qw(check_date);

# Constants.
my $DATE_WORD_HR = {
	decode_utf8('leden') => 1,
	decode_utf8('únor') => 2,
	decode_utf8('březen') => 3,
	decode_utf8('duben') => 4,
	decode_utf8('květen') => 5,
	decode_utf8('červen') => 6,
	decode_utf8('červenec') => 7,
	decode_utf8('srpen') => 8,
	decode_utf8('září') => 9,
	decode_utf8('říjen') => 10,
	decode_utf8('listopad') => 11,
	decode_utf8('prosinec') => 12,
};

# Don't buffer.
$OUTPUT_AUTOFLUSH = 1;

# URI of service.
my $base_uri = URI->new('http://www.sever.brno.cz/uredni-deska.html');

# Open a database handle.
my $dt = Database::DumpTruck->new({
	'dbname' => 'data.sqlite',
	'table' => 'data',
});

# Create a user agent object.
my $ua = LWP::UserAgent->new(
	'agent' => 'Mozilla/5.0',
);

# Look for items.
my $process_uri = $base_uri;
while ($process_uri) {
	$process_uri = process_page($process_uri);
}

# Get database date from div.
sub get_db_date_div {
	my $date_div = shift;
	my ($day, $mon, $year) = split m/\./ms, $date_div;
	remove_trailing(\$day);
	remove_trailing(\$mon);
	remove_trailing(\$year);
	if(check_date($year, $mon, $day)){
		my $time = timelocal(0, 0, 0, $day, $mon - 1, $year - 1900);
		return strftime('%Y-%m-%d', localtime($time));
	}else{
		return undef;
	}
}

# Get database data from word date.
sub get_db_date_word {
	my $date_word = shift;
	$date_word =~ s/^\s*-\s+//ms;
	my ($day, $mon_word, $year) = $date_word =~ m/^\s*(\d+)\.\s*(\w+)\s+(\d+)\s*$/ms;
	my $mon = $DATE_WORD_HR->{$mon_word};
	if(check_date($year, $mon, $day)){
		my $time = timelocal(0, 0, 0, $day, $mon - 1, $year - 1900);
		return strftime('%Y-%m-%d', localtime($time));
	}else{
		return undef;
	}
}

# Get root of HTML::TreeBuilder object.
sub get_root {
	my $uri = shift;
	my $get = $ua->get($uri->as_string);
	my $data;
	if ($get->is_success) {
		$data = $get->content;
	} else {
		die "Cannot GET '".$uri->as_string." page.";
	}
	my $tree = HTML::TreeBuilder->new;
	$tree->parse(decode_utf8($data));
	return $tree->elementify;
}

# Get link and compute MD5 sum.
sub md5 {
	my $link = shift;
	my (undef, $temp_file) = tempfile();
	my $get = $ua->get($link, ':content_file' => $temp_file);
	my $md5_sum;
	if ($get->is_success) {
		my $md5 = Digest::MD5->new;
		open my $temp_fh, '<', $temp_file;
		$md5->addfile($temp_fh);
		$md5_sum = $md5->hexdigest;
		close $temp_fh;
		unlink $temp_file;
	}
	return $md5_sum;
}

# Process page.
sub process_page {
	my $uri = shift;

	# Get base root.
	print 'Page: '.$uri->as_string."\n";
	my $root = get_root($uri);

	# Get pagination.
	my $pag_a = $root->find_by_attribute('class', 'pagination')
		->find_by_attribute('class', 'pagination-next')
		->find_by_tag_name('a');
	my $next_uri;
	if ($pag_a) {
		$next_uri = URI->new($base_uri->scheme.'://'.$base_uri->host.
			$pag_a->attr('href'));
	}

	my $doc_items = $root->find_by_attribute('class', 'items-leading');
	my @doc = $doc_items->find_by_tag_name('div');
	foreach my $doc (@doc) {
		my $doc_attr = $doc->attr('class');
		if ($doc_attr !~ m/^leading-\d+\sarticle$/ms) {
			next;
		}

		# Title and date of publication.
		my $title_h2 = $doc->find_by_tag_name('h2');
		my $title = $title_h2->find_by_tag_name('a')->as_text;
		remove_trailing(\$title);
		my $date_publication = get_db_date_word($title_h2
			->find_by_attribute('class', 'date')->as_text);

		# Category.
		my $category = $doc->find_by_attribute('class', 'category-name')
			->find_by_tag_name('a')->as_text;

		# PDF link and date of take off.
		my @td = $doc->find_by_attribute('class', 'article-anot')
			->find_by_tag_name('td');
		if (! @td) {
			next;
		}
		my $pdf_link = $base_uri->scheme.'://'.$base_uri->host.
			$td[1]->find_by_tag_name('a')->attr('href');
		my $date_take_off;
		my $last_td = pop @td;
		my $date_take_off_div = $last_td->as_text;
		if ($date_take_off_div && $date_take_off_div !~ m/^\s*$/ms) {
			$date_take_off = get_db_date_div($date_take_off_div);
		}

		# Check for update and insert.
		my $ret_ar = eval {
			$dt->execute('SELECT COUNT(*) FROM data WHERE PDF_link = ?',
				$pdf_link);
		};
		if ($EVAL_ERROR || ! @{$ret_ar} || ! exists $ret_ar->[0]->{'count(*)'}
			|| ! defined $ret_ar->[0]->{'count(*)'}
			|| $ret_ar->[0]->{'count(*)'} == 0) {

			my $md5 = md5($pdf_link);
			if (! defined $md5) {
				print "Cannot get PDF for ".
					encode_utf8($title)."\n";
			} else {
				print '- '.encode_utf8($title)."\n";
				$dt->insert({
					'Title' => $title,
					'Category' => $category,
					'PDF_link' => $pdf_link,
					'Date_of_publication' => $date_publication,
					'Date_of_take_off' => $date_take_off,
					'MD5' => $md5,
				});
				# TODO Move to begin with create_table().
				$dt->create_index(['MD5'], 'data', 1, 0);
			}
		}
	}

	# Return next URI.
	return $next_uri;
}

# Removing trailing whitespace.
sub remove_trailing {
	my $string_sr = shift;
	${$string_sr} =~ s/^\s*//ms;
	${$string_sr} =~ s/\s*$//ms;
	return;
}
