#!/usr/bin/perl
#
# Muestra los datos obtenidos por odomado.pl


use lib "/usr/local/bin";

use strict;
use DBI;
use Template;
use CGI qw/:standard/;
use Encode qw(decode encode);
use POSIX qw(strftime);
use Cache::Memcached;
use HTML::Entities;
use LWP::Simple qw/get/;
use JSON::Parse qw/parse_json/;
use odomado; # package config


sub mailq($$) ;
sub loadavg($$) ;
sub errores($$) ;
sub current($$) ;

$CGI::POST_MAX = 2048;

my $dbh  = DBI->connect($config::dsn,$config::username,$config::password) || die ("Fallo en la conexion a la base de datos");
my $memd = new Cache::Memcached({servers=>["127.0.0.1:11211"], namespace=>'odomado'}) || die ("Fallo en la conexión a Memcached");

my %valid_email = ( 'erapetti@gmail.com'=>1, 'rvsoca@gmail.com'=>1 );

my %comandos = (
	limpiar => "sudo /usr/bin/timeout --preserve-status 180s /usr/local/bin/proceso.pl --html",
	abortar => "sudo /usr/bin/timeout --preserve-status 180s /usr/local/bin/kill_smpro.pl",
);

if (!https()) {
	print redirect($config::url);
	exit(0);
}

my $page = Template->new({
    INCLUDE_PATH => '..'
});


my $cookie;
my $session = cookie('sesion');
my $userinfo;
if (!$session || !($userinfo=$memd->get("session-$session"))) {
	if (!param('idtoken')) {
		# login form
		$cookie = cookie(-name=>'sesion', -secure=>1, -samesite=>'Strict'); # la borro
		my $vars = {};
		print header(-charset=>"utf-8", -cookie=>$cookie);
		$page->process(".odomado.login.html", $vars)
		    || die $page->error();
		exit(0);
	}

	# verifico el token recibido:
	my $json = LWP::Simple::get("https://oauth2.googleapis.com/tokeninfo?id_token=".param('idtoken'));
	($json) || die "No se obtuvo la información de login desde google";
	$userinfo = parse_json($json);

	# verifico si el usuario está habilitado
	(defined($valid_email{$userinfo->{email}})) || die "Usuario $userinfo->{email} no habilitado";
	
	# genero la sesión
	my $session = sprintf "%08X%08X", rand(0xffffffff),rand(0xffffffff);
	$memd->set("session-$session",$userinfo);
	$cookie = cookie(-name=>'sesion', -value=>$session, -secure=>1, -samesite=>'Strict');
}


my $option = param('option');

if ($option eq "cmdOut") {
	my $key = param("key");
	my $status = $memd->get($key."_status");
	print header(-charset=>"utf-8",-status=>($status eq "running" ? 206 : 200));
	print "status:",$memd->get($key."_status"),"\n";
	print encode_entities($memd->get($key));
	exit(0);
}

if ($cookie) {
	print header(-charset=>"utf-8",-cookie=>$cookie);
} else {
	if (param("data")) {
		print header(-charset=>"utf-8",-type=>"application/json");
	} else {
		print header(-charset=>"utf-8");
	}
}

if ($option) {
	# llamada por AJAX


	$option =~ s/[^a-zA-Z]//g;

	my $vars = { option => $option };

	if ($option eq "mailq") {
		$vars->{title} = "Cantidad de mensajes según antigüedad";
		$vars->{values} = mailq($dbh,7);

		my %column;
		foreach my $fecha (keys %{$vars->{values}}) {
			foreach my $tipo (keys %{$vars->{values}{$fecha}}) {
				$column{$tipo} = 1;
			}
		}
		delete $column{activos};
		@{$vars->{columns}} = ((sort {$b cmp $a} keys %column),"activos");

	} elsif ($option eq "loadavg") {
		$vars->{title} = "Carga de CPU (loadavg)";
		$vars->{values} = loadavg($dbh,7);

	} elsif ($option eq "errores") {
		$vars->{title} = "Mensajes diferidos por causal";
		$vars->{values} = errores($dbh,7);

		my %column;
		foreach my $fecha (keys %{$vars->{values}}) {
			foreach my $tipo (keys %{$vars->{values}{$fecha}}) {
				$column{$tipo} = 1;
			}
		}
		@{$vars->{columns}} = sort keys %column;

	} elsif ($option eq "current") {
		$vars->{title} = "Último envío a cada lista";
		$vars->{values} = {};
		current("elcastellano.org",$vars->{values});
		current("etimologiasbrasileiras.com.br",$vars->{values});

	} elsif ($option eq "cmd" && defined($comandos{param("cmd")})) {
		my $key = sprintf "%08X%08X", rand(0xffffffff),rand(0xffffffff);
		$memd->set($key, "");
		$memd->set($key."_status", "starting");
		$vars->{nextURL} = "?option=cmdOut&key=$key";
		# continua despues de enviar el HTML
		$::key = $key;
	}

	die "ERROR: opción incorrecta: $option\n" unless(-r "../.odomado.$option.html");

	my $pagename = ".odomado.$option".(param("data") ? ".data" : "").".html";
		
	$page->process($pagename, $vars)
	    || die $page->error();

	if ($option eq "cmd" && defined($comandos{param("cmd")})) {
		# dejo corriendo el comando pedido:
		my $cmd = $comandos{param("cmd")};
		if (!$cmd) {
			$memd->set($::key."_status", "error 0: invalid command");
			exit(0);
		}
		local $| = 1; # auto flush
		exit(0) if (fork() != 0); # el padre se va
		
		# child
		close(STDIN);
		close(STDOUT);
		close(STDERR);
		my $out = "";
		if (open(CMD,"$cmd |")) {
			$memd->set($::key."_status", "running");
			while(<CMD>) {
				$out .= $_;
				$memd->set($::key, $out);
			}
			close(CMD);
		}
		$memd->set($::key."_status", $?==0 ? "ended" : "error ".($?/256).": $!");
	}
	exit(0);
}

my @estadisticas = (
	{ link=>"mailq", text=>"Cola de mensajes <i class='fas fa-redo small'></i>" },
	{ link=>"errores", text=>"Diferidos <i class='fas fa-redo small'></i>" },
	{ link=>"loadavg", text=>"Carga CPU <i class='fas fa-redo small'></i>" },
	{ link=>"current", text=>"Último envío <i class='fas fa-redo small'></i>" },
);

my @administracion = (
	{ link=>"cmd&cmd=limpiar", text=>"Limpiar", confirm=>"¿Quiere procesar las desuscripciones, eliminar duplicados y generar las sublistas 2 a 6?<br><br>Este comando corre &quot;proceso.pl&quot;"},
	{ link=>"cmd&cmd=abortar", text=>"Abortar", confirm=>"¿Quiere terminar el envío de mensajes de correo?<br><br>Este comando mata los procesos &quot;s.pl&quot; que estén corriendo"},
);

my $vars = {
	menu_estadisticas => \@estadisticas,
	menu_administracion => \@administracion,
	avatar => $userinfo->{picture},
	css_version => (stat "../odomado.css")[9],
	url => $config::url;
};

$page->process(".odomado.html", $vars)
    || die $page->error();

exit(0);

######################################################################

sub mailq($$) {
	my ($dbh,$dias) = @_;

	my $sql = "select date_format(fecha,'%Y-%m-%d %H:%i')fecha,if(tipo='activos',tipo,concat(tipo,' días'))tipo,avg(valor)valor from monitor where categoria='mq' and fecha>=date_sub(now(),interval $dias day) and tipo<>'' group by 1,2";
	my $sth = $dbh->prepare($sql);
	$sth->execute();

	my %result;
	while(my @row = $sth->fetchrow_array) {
		$result{$row[0]}{$row[1]} = $row[2];
	}
	$sth->finish;
	return \%result;
}

sub loadavg($$) {
	my ($dbh,$dias) = @_;

	my $sql = "select date_format(fecha,'%d-%b %H:%i')fecha,max(if(tipo=1,valor,0))1min,max(if(tipo=5,valor,0))5min,max(if(tipo=15,valor,0))15min from monitor where categoria='loadavg' and fecha>=date_sub(now(),interval $dias day) group by 1 order by 1";
	my $sth = $dbh->prepare($sql);
	$sth->execute();

	my $result = $sth->fetchall_arrayref;

	$sth->finish;
	return $result;
}

sub errores($$) {
	my ($dbh,$dias) = @_;

	my $sql = "select date_format(fecha,'%d-%b %H:%i')fecha,tipo,sum(valor)valor from monitor where categoria='errores' and fecha>=date_sub(now(),interval $dias day) group by 1,2 order by 1,2";
	my $sth = $dbh->prepare($sql);
	$sth->execute();

	my $result;

	while(my @row = $sth->fetchrow_array) {
		$result->{$row[0]}{$row[1]} = $row[2];
	}
	$sth->finish;
	return $result;
}

sub current($$) {
	my ($site, $rresult) =@_;

	my $DIRBASE = "/var/www/vhosts/$site/httpdocs/cgi-bin/smpro_db";

	($site eq "elcastellano.org") and $DIRBASE =~ s/httpdocs/listas/;

	$site =~ s/\./_/g; # los puntos molestan

	$rresult->{$site} = {}; # creo donde voy a devolver la info
	$rresult = $rresult->{$site}; # sigo trabajando solo con este sitio

	# last date
	opendir(DIR,"$DIRBASE/maildir") || die "No se puede abrir $DIRBASE: $!";
	foreach $_ (readdir(DIR)) {
		next if (!/^(\d+)-(\d+)-(\d+)-(\d+)-(\d+)-(\d+)-count\.txt$/);

		my $lista = $1;
		my $fecha = sprintf "%4d-%02d-%02d %02d:%02d",$4,$2,$3,$5,$6;
		next if (defined($rresult->{$lista}) && $rresult->{$lista}{fecha} gt $fecha);
		$rresult->{$lista}{fecha} = $fecha;
		$rresult->{$lista}{filename} = $_;
		$rresult->{$lista}{mtime} = (stat("$DIRBASE/maildir/$_"))[9];
		$rresult->{$lista}{stalled} = (time() - $rresult->{$lista}{mtime}) > 30*60;
		$rresult->{$lista}{fmt_mtime} = strftime("%Y-%m-%d %T GMT%z", localtime($rresult->{$lista}{mtime}));
	}
	closedir(DIR);

	# progress and list name
	foreach my $lista (keys %$rresult) {
		open(FILE,"$DIRBASE/maildir/".$rresult->{$lista}{filename}) || die "$!";
		$_ = <FILE>;
		chop();
		@_ = split (',');
		$rresult->{$lista}{count} = $_[0]+1;
		$rresult->{$lista}{name} = encode("utf-8", $_[2]);
		$rresult->{$lista}{name} =~ s/"/'/g;
		$DIRBASE =~ /vhosts\/(.*?)\// and $rresult->{$lista}{site} = $1;
		close(FILE);

		if (! open(FILE,"$DIRBASE/lists/$lista.list")) {
			# la lista ya no existe
			delete $rresult->{$lista};
			next;
		}
		$rresult->{$lista}{total} = 0;
		while(<FILE>) {
			$rresult->{$lista}{total} ++;
		}
		close(FILE);
		$rresult->{$lista}{avance} = $rresult->{$lista}{total}>0 ? sprintf "%d", 100*$rresult->{$lista}{count}/$rresult->{$lista}{total} : 100;
	}
}

sub smpro_sid() {
	my $sid;

	my $DIRBASE = "/var/www/vhosts/elcastellano.org/listas/cgi-bin/smpro_db";

	open(FILE,"$DIRBASE/info/session.id");
	$sid = <FILE>;
	close(FILE);

	return $sid;
}
