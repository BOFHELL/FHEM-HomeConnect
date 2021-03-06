=head1
        48_HomeConnect.pm

# $Id: $

        Version 0.1

=head1 SYNOPSIS
        Bosch Siemens Home Connect Modul for FHEM
        contributed by Stefan Willmeroth 09/2016

=head1 DESCRIPTION
        98_HomeConnect handle individual Home Connect devices via the
        96_HomeConnectConnection

=head1 AUTHOR - Stefan Willmeroth
        swi@willmeroth.com (forum.fhem.de)
=cut

package main;

use strict;
use warnings;
use JSON;
use Switch;
require 'HttpUtils.pm';

##############################################
my %HomeConnect_Iconmap = (
  "Dishwasher"    => "scene_dishwasher",
  "Oven"          => "scene_baking_oven",
  "FridgeFreezer" => "scene_wine_cellar",	#fixme
  "Washer"        => "scene_washing_machine",
  "Dryer"         => "scene_clothes_dryer",
  "CoffeeMaker"   => "max_heizungsthermostat"   #fixme
);

my @HomeConnect_SettablePgmOptions = (
  "Cooking.Oven.Option.SetpointTemperature",
  "BSH.Common.Option.Duration",
  "BSH.Common.Option.StartInRelative"
);

##############################################
sub HomeConnect_Initialize($)
{
  my ($hash) = @_;

  $hash->{SetFn}     = "HomeConnect_Set";
  $hash->{DefFn}     = "HomeConnect_Define";
  $hash->{GetFn}     = "HomeConnect_Get";
  $hash->{AttrList}  = "updateTimer";
}

###################################
sub HomeConnect_Set($@)
{
  my ($hash, @a) = @_;
  my $rc = undef;
  my $reDOUBLE = '^(\\d+\\.?\\d{0,2})$';
  my $haId = $hash->{haId};
  my $cmdPrefix = $hash->{commandPrefix};
  my $programs = $hash->{programs};

  my $remoteStartAllowed = ReadingsVal($hash->{NAME}, "BSH.Common.Status.RemoteControlStartAllowed","0");
  my $operationState = ReadingsVal($hash->{NAME}, "BSH.Common.Status.OperationState","0");

  my $pgmRunning =($operationState eq "BSH.Common.EnumType.OperationState.Active" || 
        $operationState eq "BSH.Common.EnumType.OperationState.DelayedStart" ||
        $operationState eq "BSH.Common.EnumType.OperationState.Run");

  my $availableCmds;
  my $availableOpts="";

  foreach my $reading (keys $hash->{READINGS}) {
    if (index ($reading,".Option.")>0 && grep( /^$reading$/, @HomeConnect_SettablePgmOptions )) {
      $availableOpts .= " ".$reading;
    }
  }

  if (!defined $hash->{type}) {
    if (Value($hash->{hcconn}) ne "Logged in") {
      $availableCmds = "init";
    }
  } elsif ($pgmRunning) {
    $availableCmds = "stopProgram";
    $availableCmds.=$availableOpts if (length($availableOpts)>0);
  } else {
    if ($remoteStartAllowed) {
      $availableCmds = "startProgram:$programs requestProgramOptions:$programs";
      $availableCmds.=$availableOpts if (length($availableOpts)>0);
    } else {
      $availableCmds = "startProgram:RemoteStartNotEnabled";
    }
  }

  return "no set value specified" if(int(@a) < 2);
  return $availableCmds if($a[1] eq "?");

  shift @a;
  my $command = shift @a;

  Log 4, "$hash->{NAME} set command: $command";

  ## Start a program
  if($command eq "startProgram") {
    return "A program is already running" if ($pgmRunning);

    return "Please enable remote start on your appliance to start a program" if (!$remoteStartAllowed);

    my $pgm = shift @a;
    if (!defined $pgm || index($programs,$pgm) == -1) {
      return "Unknown program $pgm, choose one of $programs";
    }

    my $options="";
    foreach my $key ( @HomeConnect_SettablePgmOptions ) {
      my $optval = ReadingsVal($hash->{NAME},$key,undef);
      if (defined $optval) {
        my @a = split("[ \t][ \t]*", $optval);
        $options .= "," if (length($options)>0);
        $options .= "{\"key\":\"$key\",\"value\":$a[0]";
        $options .= ",\"unit\":\"$a[1]\"" if defined $a[1];
        $options .= "}";
      }
    }
    my $URL = "/api/homeappliances/$haId/programs/active";
    HomeConnectConnection_putrequest($hash,$URL,"{\"data\":{\"key\":\"$cmdPrefix$pgm\",\"options\":[$options]}}");

  }
  ## Stop current program
  if($command eq "stopProgram") {
    return "No program is running" if (!$pgmRunning);
    my $URL = "/api/homeappliances/$haId/programs/active";
    HomeConnectConnection_delrequest($hash,$URL);
  }
  ## Set options, update current program if needed
  if(index($availableOpts,$command)>-1) {
    my $optval = shift @a;
    if (!defined $optval) {
      return "Need to supply a new option value";
    }
    readingsBeginUpdate($hash);
    readingsBulkUpdate($hash, $command, $optval);
    readingsEndUpdate($hash, 1);

    if ($pgmRunning) {
      my $URL = "/api/homeappliances/$haId/programs/active/options/$command";
      HomeConnectConnection_putrequest($hash,$URL,"{\"data\":{\"key\":\"$command\",\"value\":\"$optval\"}}");
    }

  }
  ## Connect to Home Connect server, update status
  if($command eq "init") {
    return HomeConnect_Init($hash);
  }
  ## Request options for selected program
  if($command eq "requestProgramOptions") {
    my $pgm = shift @a;
    if (!defined $pgm || index($programs,$pgm) == -1) {
      return "Unknown program $pgm, choose one of $programs";
    }
    HomeConnect_GetProgramOptions($hash,$pgm);
  }
  return $rc;
}

#####################################
sub HomeConnect_Define($$)
{
  my ($hash, $def) = @_;
  my @a = split("[ \t][ \t]*", $def);

  my $u = "wrong syntax: define <dev-name> HomeConnect <conn-name> <haId> to add appliances";

  return $u if(int(@a) < 4);

  $hash->{hcconn} = $a[2];
  $hash->{haId} = $a[3];

  #### Delay init if not yet connected
  return undef if(Value($hash->{hcconn}) ne "Logged in");

  return HomeConnect_Init($hash);
}

#####################################
sub HomeConnect_Init($)
{
  my ($hash) = @_;
  my $JSON = JSON->new->utf8(0)->allow_nonref;

  #### Read list of appliances, find my haId
  my $URL = "/api/homeappliances";

  my $applianceJson = HomeConnectConnection_request($hash,$URL);
  if (!defined $applianceJson) {
    return "Failed to connect to HomeConnect API, see log for details";
  }

  my $appliances = $JSON->decode ($applianceJson);

  for (my $i = 0; 1; $i++) {
    my $appliance = $appliances->{data}->{homeappliances}[$i];
    if (!defined $appliance) { last };
    if ($hash->{haId} eq $appliance->{haId}) {
      $hash->{aliasname} = $appliance->{name};
      $hash->{type} = $appliance->{type};
      $hash->{brand} = $appliance->{brand};
      $hash->{vib} = $appliance->{vib};
      $hash->{connected} = $appliance->{connected};
      Log 2, "$hash->{NAME} defined HomeConnect $hash->{type} $hash->{brand} $hash->{vib}, connected $hash->{connected}";

      my $icon = $HomeConnect_Iconmap{$appliance->{type}};

      $attr{$hash->{NAME}}{icon} = $icon if (!defined $attr{$hash->{NAME}}{icon} && defined $icon);
      $attr{$hash->{NAME}}{alias} = $hash->{aliasname} if (!defined $attr{$hash->{NAME}}{alias} && defined $hash->{aliasname});
      $attr{$hash->{NAME}}{webCmd} = "startProgram:stopProgram" if (!defined $attr{$hash->{NAME}}{webCmd});

      HomeConnect_GetPrograms($hash);
      HomeConnect_UpdateStatus($hash);
      RemoveInternalTimer($hash);
      HomeConnect_CloseEventChannel($hash);
      HomeConnect_Timer($hash);
      return undef;
    }
  }
  return "Specified appliance with haId $hash->{haId} not found";
}

#####################################
sub HomeConnect_Undef($$)
{
   my ( $hash, $arg ) = @_;

   RemoveInternalTimer($hash);
   HomeConnect_CloseEventChannel($hash);
   Log 3, "--- removed ---";
   return undef;
}

#####################################
sub HomeConnect_Get($@)
{
  my ($hash, @args) = @_;

  return 'HomeConnect_Get needs two arguments' if (@args != 2);

  my $get = $args[1];
  my $val = $hash->{Invalid};

#  if (defined($hash->{READINGS}{$get})) {
#    $val = $hash->{READINGS}{$get}{VAL};
#  } else {
#    my @cList = keys ($hash->{READINGS});
#    return "HomeConnect_Get: no such reading: $get, choose one of " . join(" ", @cList);
#  }

  return "HomeConnect_Get: no such reading: $get, choose one of dummy";

  Log 3, "$args[0] $get => $val";

  return $val;
}

#####################################
sub HomeConnect_Timer
{
  my ($hash) = @_;
  my $name   = $hash->{NAME};

  my $updateTimer = AttrVal($name, "updateTimer", 10);

  if (!defined $hash->{conn}) {
    HomeConnect_ConnectEventChannel($hash);
  } else {
    HomeConnect_ReadEventChannel($hash);
  }

  InternalTimer( gettimeofday() + $updateTimer, "HomeConnect_Timer", $hash, 0);
}

#####################################
sub HomeConnect_GetProgramOptions
{
  my ($hash, $program) = @_;
  my %readings = ();
  my $haId = $hash->{haId};
  my $cmdPrefix = $hash->{commandPrefix};
  my $JSON = JSON->new->utf8(0)->allow_nonref;

  my $URL = "/api/homeappliances/$haId/programs/available/$cmdPrefix$program";
  my $json = HomeConnectConnection_request($hash,$URL);

  if (defined $json) {
    my $parsed = $JSON->decode ($json);

    HomeConnect_parseOptionsToHash2(\%readings,$parsed);

    readingsBeginUpdate($hash);
    for my $get (keys %readings) {
      readingsBulkUpdate($hash, $get, $readings{$get});
    }
    readingsEndUpdate($hash, 1);
  }
}

#####################################
sub HomeConnect_GetPrograms
{
  my ($hash) = @_;
  my %readings = ();
  my $haId = $hash->{haId};
  my @pgms = ();
  my $prefix;

  my $programs = "";
  my $JSON = JSON->new->utf8(0)->allow_nonref;

  my $operationState = ReadingsVal($hash->{NAME},"BSH.Common.Status.OperationState","");
  my $activeProgram = ReadingsVal($hash->{NAME},"BSH.Common.Root.ActiveProgram",undef);

  if ($operationState eq "BSH.Common.EnumType.OperationState.Active" ||
      $operationState eq "BSH.Common.EnumType.OperationState.DelayedStart" ||
      $operationState eq "BSH.Common.EnumType.OperationState.Run") {
    if (defined $activeProgram) {
      #### Currently we dont get a list of programs if a program is active, so we just use the active program name
      my $prefix = HomeConnect_checkPrefix(undef, $activeProgram);
      my $prefixLen = length $prefix;
      $hash->{commandPrefix} = $prefix;
      $hash->{programs} = substr($activeProgram, $prefixLen);
    }
    return undef;
  }
  #### Request available programs
  my $URL = "/api/homeappliances/$haId/programs/available";
  my $json = HomeConnectConnection_request($hash,$URL);

  if (defined $json) {
    my $parsed = $JSON->decode ($json);
    for (my $i = 0; 1; $i++) {
      my $programline = $parsed->{data}->{programs}[$i];
      if (!defined $programline) { last };
      push (@pgms, $programline->{key});
      $prefix = HomeConnect_checkPrefix($prefix, $programline->{key});
    }
    #### command beautyfication: remove a common prefix
    my $prefixLen = length $prefix;
    foreach my $program (@pgms) {
      if ($programs ne "") {
        $programs .= ",";
      }
      $programs .= substr($program, $prefixLen);
    }
    $hash->{commandPrefix} = $prefix;
    $hash->{programs} = $programs;
  }
}
#####################################
sub HomeConnect_checkPrefix
{
  my ($prefix, $value) = @_;

  if (!defined $prefix) {
    $value =~ /(.*)\..*$/;
    return $1.".";
  } else {
    for (my $i=0; $i < length $value; $i++) {
      if (substr($prefix, $i, 1) ne substr($value, $i, 1)) {
        return substr($prefix, 0, $i);
      }
    }
    return $value;
  }
}

#####################################
sub HomeConnect_parseOptionsToHash
{
  my ($parsed) = @_;
  my %options = ();

  for (my $i = 0; 1; $i++) {
    my $optionsline = $parsed->{data}->{options}[$i];
    if (!defined $optionsline) { last };
    my $key = $optionsline->{key};
#    $key =~ tr/\\./_/;
    $options{ $key } = "$optionsline->{value} $optionsline->{unit}";
    Log 3,"$key = $optionsline->{value} $optionsline->{unit}";
  }
  return \%options;
}

#####################################
sub HomeConnect_parseOptionsToHash2
{
  my ($hash,$parsed) = @_;

  for (my $i = 0; 1; $i++) {
    my $optionsline = $parsed->{data}->{options}[$i];
    if (!defined $optionsline) { last };
    my $key = $optionsline->{key};
#    $key =~ tr/\\./_/;
    $hash->{$key} = "$optionsline->{value}";
    $hash->{$key} .= " $optionsline->{unit}" if (defined $optionsline->{unit});
#    Log 3,"$key = $optionsline->{value} $optionsline->{unit}";
  }
}

#####################################
sub HomeConnect_ShortenKey
{
  my ($key) = @_;
  my ($b,$c) = $a =~ m|^(.*[\.])([^\.]+?)$|;
  return $c;
}

#####################################
sub HomeConnect_UpdateStatus
{
  my ($hash) = @_;
  my %readings = ();
  my $haId = $hash->{haId};
  my $JSON = JSON->new->utf8(0)->allow_nonref;

  #### Get status variables
  my $URL = "/api/homeappliances/$haId/status";
  my $json = HomeConnectConnection_request($hash,$URL);

  if (!defined $json) {
    # no status available
    $hash->{STATE} = "Unknown";
    return undef;
  }

  my $parsed = $JSON->decode ($json);

  for (my $i = 0; 1; $i++) {
    my $statusline = $parsed->{data}->{status}[$i];
    if (!defined $statusline) { last };
    $readings{$statusline->{key}} = $statusline->{value};
    $readings{$statusline->{key}}.=" ".$statusline->{unit} if defined $statusline->{unit};
  }

  my $operationState = $readings{"BSH.Common.Status.OperationState"};
  my $pgmRunning = defined $operationState &&
       ($operationState eq "BSH.Common.EnumType.OperationState.Active" ||
        $operationState eq "BSH.Common.EnumType.OperationState.DelayedStart" ||
        $operationState eq "BSH.Common.EnumType.OperationState.Run"
       );

  #### Check for a running program
  if ($pgmRunning) {
    $URL = "/api/homeappliances/$haId/programs/active";
    $json = HomeConnectConnection_request($hash,$URL);
  } else {
    undef $json;
  }

  if (!defined $json) {
    # no program running
    $readings{state} = "Idle";
    $readings{"BSH.Common.Root.ActiveProgram"} = "None";
    $readings{"BSH.Common.Option.RemainingProgramTime"} = "0 seconds";
    $readings{"BSH.Common.Option.ProgramProgress"} = "0 %";
  } else {
    my $parsed = $JSON->decode ($json);
    $readings{"BSH.Common.Root.ActiveProgram"} = $parsed->{data}->{key};
    HomeConnect_parseOptionsToHash2(\%readings,$parsed);
    $readings{state} = "Program active";
    $readings{state} .= " (".$readings{"BSH.Common.Option.ProgramProgress"} .")"
          if defined $readings{"BSH.Common.Option.ProgramProgress"};
  }

  #### Update Readings
  readingsBeginUpdate($hash);

  for my $get (keys %readings) {
    readingsBulkUpdate($hash, $get, $readings{$get});
  }

  readingsEndUpdate($hash, 1);

  return "HomeConnect new state is ". $hash->{STATE};
}

#####################################
sub HomeConnect_ConnectEventChannel
{
  my ($hash) = @_;
  my $haId = $hash->{haId};
  my $api_uri = $defs{$hash->{hcconn}}->{api_uri};

  my $param = {
    url => "$api_uri/api/homeappliances/$haId/events",
    hash       => $hash,
    timeout    => 10,
    noshutdown => 1,
    noConn2    => 1,
    callback   => \&HomeConnect_HttpConnected
  };

  HttpUtils_NonblockingGet($param);

}

#####################################
sub HomeConnect_HttpConnected
{
  my ($param, $err, $data) = @_;
  my $hash = $param->{hash};
  my $name = $hash->{NAME};

  my ($gterror, $token) = getKeyValue($hash->{hcconn}."_accessToken");

  my $method = $param->{method};

  $method = ($data ? "POST" : "GET") if( !$method );

  my $httpVersion = $param->{httpversion} ? $param->{httpversion} : "1.0";
  my $hdr = "$method $param->{path} HTTP/$httpVersion\r\n";
  $hdr .= "Host: $param->{host}\r\n";
  $hdr .= "User-Agent: fhem\r\n" if(!$param->{header} || $param->{header} !~ "User-Agent:");
  $hdr .= "Accept: text/event-stream\r\n";
  $hdr .= "Accept-Encoding: gzip,deflate\r\n" if($param->{compress});
  $hdr .= "Connection: keep-alive\r\n" if($param->{keepalive});
  $hdr .= "Connection: Close\r\n" if($httpVersion ne "1.0" && !$param->{keepalive});
  $hdr .= "Authorization: Bearer $token\r\n";
  if(defined($data)) {
    $hdr .= "Content-Length: ".length($data)."\r\n";
    $hdr .= "Content-Type: application/x-www-form-urlencoded\r\n" if ($hdr !~ "Content-Type:");
  }
  $hdr .= "\r\n";

  syswrite $param->{conn}, $hdr;
  $hash->{conn} = $param->{conn};
}

#####################################
sub HomeConnect_CloseEventChannel($)
{
  my ( $hash ) = @_;

  if (defined $hash->{conn}) {
    $hash->{conn}->close();
    undef $hash->{conn};
  }
} 

#####################################
sub HomeConnect_ReadEventChannel($)
{
  my ($hash) = @_;
  my $inputbuf = "";
  my $JSON = JSON->new->utf8(0)->allow_nonref;

  if (defined $hash->{conn}) {
    my ($rout, $rin) = ('', '');
    vec($rin, $hash->{conn}->fileno(), 1) = 1;
    while (1) {
      my $nfound = select($rout=$rin, undef, undef, 0);
      if($nfound < 0) {
        Log 2,"Channel timeout/error: $!";
        HomeConnect_CloseEventChannel($hash);
        return undef;
      }
      if($nfound > 0) {
        my $buf;
        my $len = sysread($hash->{conn},$buf,1);
        if(defined($len) && $len > 0) {
          $inputbuf .= $buf if(defined($len) && $len > 0);
        } else {
          Log 2,"Nothing to read, channel closed";
          HomeConnect_CloseEventChannel($hash);
          return undef;
        }
      }
      else {
        ## exit the loop
        last;
      }
    }
    if (length $inputbuf > 0) {
      Log 4,$hash->{NAME}." received: $inputbuf";

      readingsBeginUpdate($hash);

      for (split /^/, $inputbuf) {
        if (index($_,"data:") == 0) {
          if (length ($_) < 10) { next };
          my $json = substr($_,5);
          Log 4,$hash->{NAME}." data: $json";
          my $parsed = $JSON->decode ($json);

          #### Update Readings
          my %readings = ();
          for (my $i = 0; 1; $i++) {
            my $item = $parsed->{items}[$i];
            if (!defined $item) { last };
            my $key = $item->{key};
            $readings{$key}=(defined $item->{value})?$item->{value}:"-";
            $readings{$key}.=" ".$item->{unit} if defined $item->{unit};
            readingsBulkUpdate($hash, $key, $readings{$key});
            Log 4,$hash->{NAME}." $key = $readings{$key}";
          }

          my $state;
          my $operationState = ReadingsVal($hash->{NAME},"BSH.Common.Status.OperationState","");
          my $program = ReadingsVal($hash->{NAME},"BSH.Common.Root.ActiveProgram","");
          if (defined($hash->{commandPrefix})) {
            my $prefixLen = length $hash->{commandPrefix};
            $program = substr($program, $prefixLen);
          }
          if ($operationState eq "BSH.Common.EnumType.OperationState.Active" ||
              $operationState eq "BSH.Common.EnumType.OperationState.Run") {

            $state = "Program $program active";
            my $pct = ReadingsVal($hash->{NAME},"BSH.Common.Option.ProgramProgress",undef);
            $state .= " ($pct)" if (defined $pct);
          } elsif ($operationState eq "BSH.Common.EnumType.OperationState.DelayedStart") {
            $state = "Delayed start of program $program";
          } else {
            $state = "Idle";
          }
          readingsBulkUpdate($hash, "state", $state) if ($hash->{STATE} ne $state);
        }
      }
      readingsEndUpdate($hash, 1);
    }
  }
}



1;

=pod
=begin html

<a name="HomeConnect"></a>
<h3>HomeConnect</h3>
<ul>
  <a name="HomeConnect_define"></a>
  <h4>Define</h4>
  <ul>
    <code>define &lt;name&gt; HomeConnect &lt;connection&gt; &lt;haId&gt;</code>
    <br/>
    <br/>
    Defines a single Home Connect household appliance. See <a href="http://www.home-connect.com/">Home Connect</a>.<br><br>
    Example:

    <code>define Dishwasher HomeConnect hcconn SIEMENS-HCS02DWH1-83D908F0471F71</code><br>

    <br/>
	Typically the Home Connect devices are created automatically by the scanDevices action in HomeConnectConnection.
    <br/>
  </ul>

  <a name="HomeConnect_set"></a>
  <b>Set</b>
  <ul>
    <li>startProgram<br>
      Start a program on the appliance. The programs name must be given as first parameter.
      The program will be started with specific options.
      </li>
    <li>stopProgram<br>
      Stop the running program on the appliance.
      </li>
    <li>requestProgramOptions<br>
      Read options for a specific program for the appliance and add them to Readings for later editing.
      </li>
  </ul>
  <br>

  <a name="HomeConnect_Attr"></a>
  <h4>Attributes</h4>
  <ul>
    <li><a name="updateTimer"><code>attr &lt;name&gt; updateTimer &lt;Integer&gt;</code></a>
                <br />Interval for update checks, default is 10 seconds</li>
  </ul>
</ul>

=end html
=cut
