#!/usr/bin/perl
#
# odomado_task.pl
#
#	Agente de odomado
#	El resultado se ve usando /cgi-bin/odomado.pl


use lib "/usr/local/bin";

use strict;
use DBI;
use odomado; # package config

sub create_time($) ;
sub active($) ;
sub defer($$) ;

my $dbh  = DBI->connect($config::dsn,$config::username,$config::password) || die ("Fallo en la conexion a la base de datos");

chdir "/var/spool/postfix";

my $time = time();

my (%reason,%cantidad);

defer(\%reason, \%cantidad);
active(\%cantidad);


my ($sql,$sth);

# mensajes pendientes
$sql = 'insert into monitor (categoria,fecha,tipo,valor) values ("mq",from_unixtime(?),?,?)';
$sth = $dbh->prepare($sql);
foreach my $tipo (keys %cantidad) {
	$sth->execute($time,$tipo,$cantidad{$tipo});
}
$sth->finish;

# errores
$sql = 'insert into monitor (categoria,fecha,tipo,valor) values ("errores",from_unixtime(?),?,?)';
$sth = $dbh->prepare($sql);

my $otros = 0;
foreach $_ (sort {$reason{$b} <=> $reason{$a}} keys %reason) {
	if ($reason{$_} < 100) {
		$otros += $reason{$_};
		next;
	}
	$sth->execute($time,$_,$reason{$_});
}
$sth->execute($time,"Other",$otros);
$sth->finish;

# loadavg
$sql = 'insert into monitor (categoria,fecha,tipo,valor) values ("loadavg",from_unixtime(?),?,?)';
$sth = $dbh->prepare($sql);

$_ = `/usr/bin/uptime`;
/load average: ([\d.]+), ([\d.]+), ([\d.]+)$/;
my ($load1, $load5, $load15) = ($1, $2, $3);

$sth->execute($time,"1",$load1);
$sth->execute($time,"5",$load5);
$sth->execute($time,"15",$load15);
$sth->finish;



exit(0);

######################################################################

sub create_time($) {
        my ($filename) = @_;

        open(FILE,"deferred/$filename") || die "deferred/".$filename;
#        open(FILE,"deferred/".$filename) || return;

        my $content;
        read(FILE,$content,256);
        close(FILE);

        $content =~ /create_time=(\d{10,10})/ and return $1;

        return;
}

sub active($) {
	my ($rcant) = @_;

	opendir(ACTIVE,"active");
	foreach my $dir (readdir(ACTIVE)) {

		next if ($dir =~ /^\.\.?$/);
		next if (! -f "active/$dir");

		$rcant->{activos}++;
	}
}

sub defer($$) {
	my ($rreason,$rcantidad) = @_;

	my $time = time();

	opendir(DEFER,"defer");
	foreach my $dir (readdir(DEFER)) {
		next if ($dir =~ /^\.\.?$/);
		next if (! -d "defer/$dir");

		opendir(DIR,"defer/$dir");
		foreach my $file (readdir(DIR)) {
			next if (! -f "defer/$dir/$file");

			my $tipo = sprintf "%d", ($time - (create_time("$dir/$file")||$time)) / 86400; # cantidad de dias que hace que fue creado
			$rcantidad->{$tipo}++;

			open(FILE,"defer/$dir/$file");
			while(<FILE>) {
				if (/^reason=(.*)/) {
					my $reason = $1;
					$reason =~ s/.*said: //;
					$reason =~ s/ name=[^ ]+//;
					$reason =~ s/^451.* \(S777..\).*/outlook server busy/;
					$reason =~ s/^delivery temporarily suspended: connect to.*Connection timed out/Connection timed out/;
					$reason =~ s/^delivery temporarily suspended: Host or domain name not found. Name service error.*/Name service error/;
					$reason =~ s/^delivery temporarily suspended: connect to.*Connection refused/Connection refused/;
					$reason =~ s/^Host or domain name not found.*/Host or domain name not found/;
					$reason =~ s/^connect to.*: ([^:]+)$/$1/;
					$reason =~ s/^lost connection.*/lost connection/;
					$reason =~ s/^delivery temporarily suspended.*/delivery temporarily suspended/;
					$reason =~ s/.*(over quota|overquota).*/Over quota/i;
					$reason =~ s/.*(Access denied).*/Access denied/i;
					$reason =~ s/.*blocked using Trend Micro Email Reputation Service.*/Trend Micro/;
					$reason =~ s/\[[0-9a-f.:]+\]//g;
					$reason = substr($reason,0,64);
					$rreason->{$reason} ++;
					last;
				}
			}
			close(FILE);
		}
		close(DIR);
	}
	closedir(DEFER);
}
