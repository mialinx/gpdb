# TestLib, low-level routines and actions regression tests.
#
# This module contains a set of routines dedicated to environment setup for
# a PostgreSQL regression test run and includes some low-level routines
# aimed at controlling command execution, logging and test functions. This
# module should never depend on any other PostgreSQL regression test modules.

package TestLib;

use strict;
use warnings;

use Config;
use Exporter 'import';
use File::Basename;
use File::Spec;
use File::Temp ();
use IPC::Run;
use SimpleTee;

# specify a recent enough version of Test::More  to support the note() function
use Test::More 0.82;

our @EXPORT = qw(
  tempdir
  tempdir_short
  standard_initdb
  configure_hba_for_replication
  start_test_server
  restart_test_server
  psql
  slurp_dir
  slurp_file
  system_or_bail
  system_log
  run_log
  run_command

  command_ok
  command_fails
  command_exit_is
  program_help_ok
  program_version_ok
  program_options_handling_ok
  command_like
  command_warns_like
  command_fails_like
  issues_sql_like
  run_cmd_until
  wait_until_file_exists

  $tmp_check
  $log_path
  $windows_os
);

use Cwd;
use File::Basename;
use File::Spec;
use File::Temp ();
use IPC::Run qw(run start);

use SimpleTee;

use Test::More;

our $windows_os = $Config{osname} eq 'MSWin32' || $Config{osname} eq 'msys';

# Open log file. For each test, the log file name uses the name of the
# file launching this module, without the .pl suffix.
our ($tmp_check, $log_path);
$tmp_check = $ENV{TESTDIR} ? "$ENV{TESTDIR}/tmp_check" : "tmp_check";
$log_path = "$tmp_check/log";
mkdir $tmp_check;
mkdir $log_path;
my $test_logfile = basename($0);
$test_logfile =~ s/\.[^.]+$//;
$test_logfile = "$log_path/regress_log_$test_logfile";
open TESTLOG, '>', $test_logfile or die "Cannot open STDOUT to logfile: $!";

# Hijack STDOUT and STDERR to the log file
open(ORIG_STDOUT, ">&STDOUT");
open(ORIG_STDERR, ">&STDERR");
open(STDOUT, ">&TESTLOG");
open(STDERR, ">&TESTLOG");

# The test output (ok ...) needs to be printed to the original STDOUT so
# that the 'prove' program can parse it, and display it to the user in
# real time. But also copy it to the log file, to provide more context
# in the log.
my $builder = Test::More->builder;
my $fh = $builder->output;
tie *$fh, "SimpleTee", *ORIG_STDOUT, *TESTLOG;
$fh = $builder->failure_output;
tie *$fh, "SimpleTee", *ORIG_STDERR, *TESTLOG;

# Enable auto-flushing for all the file handles. Stderr and stdout are
# redirected to the same file, and buffering causes the lines to appear
# in the log in confusing order.
autoflush STDOUT 1;
autoflush STDERR 1;
autoflush TESTLOG 1;

# Set to untranslated messages, to be able to compare program output
# with expected strings.
delete $ENV{LANGUAGE};
delete $ENV{LC_ALL};
$ENV{LC_MESSAGES} = 'C';

delete $ENV{PGCONNECT_TIMEOUT};
delete $ENV{PGDATA};
delete $ENV{PGDATABASE};
delete $ENV{PGHOSTADDR};
delete $ENV{PGREQUIRESSL};
delete $ENV{PGSERVICE};
delete $ENV{PGSSLMODE};
delete $ENV{PGUSER};

if (!$ENV{PGPORT})
{
	$ENV{PGPORT} = 65432;
}

# Force a sane value of PGPORT
$ENV{PGPORT} = int($ENV{PGPORT});
if ($ENV{PGPORT} < 1024 || $ENV{PGPORT} > 65535)
{
	$ENV{PGPORT} = ($ENV{PGPORT} % 16384) + 49152;
}


#
# Helper functions
#
sub tempdir
{
	return File::Temp::tempdir(
		'tmp_testXXXX',
		DIR => $tmp_check,
		CLEANUP => 1);
}

sub tempdir_short
{

	# Use a separate temp dir outside the build tree for the
	# Unix-domain socket, to avoid file name length issues.
	return File::Temp::tempdir(CLEANUP => 1);
}

# Translate a Perl file name to a host file name.  Currently, this is a no-op
# except for the case of Perl=msys and host=mingw32.  The subject need not
# exist, but its parent directory must exist.
sub perl2host
{
	my ($subject) = @_;
	return $subject unless $Config{osname} eq 'msys';
	my $here = cwd;
	my $leaf;
	if (chdir $subject) {
		$leaf = '';
	}
	else {
		$leaf = '/' . basename $subject;
		my $parent = dirname $subject;
		chdir $parent or die "could not chdir \"$parent\": $!";
	}

	# this odd way of calling 'pwd -W' is the only way that seems to work.
	my $dir = qx{sh -c "pwd -W"};
	chomp $dir;
	chdir $here;
	return $dir . $leaf;
}

# Initialize a new cluster for testing.
#
# The PGHOST environment variable is set to connect to the new cluster.
#
# Authentication is set up so that only the current OS user can access the
# cluster. On Unix, we use Unix domain socket connections, with the socket in
# a directory that's only accessible to the current user to ensure that.
# On Windows, we use SSPI authentication to ensure the same (by pg_regress
# --config-auth).
sub standard_initdb
{
	my $pgdata = shift;
	system_or_bail('initdb', '-D', "$pgdata", '-A' , 'trust', '-N');
	system_or_bail($ENV{PG_REGRESS}, '--config-auth', $pgdata);

	my $tempdir_short = tempdir_short;

	open CONF, ">>$pgdata/postgresql.conf";
	print CONF "\n# Added by TestLib.pm)\n";
	print CONF "fsync = off\n";
	if ($windows_os)
	{
		print CONF "listen_addresses = '127.0.0.1'\n";
	}
	else
	{
		print CONF "unix_socket_directories = '$tempdir_short'\n";
		print CONF "listen_addresses = ''\n";
	}
	close CONF;

	$ENV{PGHOST}         = $windows_os ? "127.0.0.1" : $tempdir_short;
}

# Set up the cluster to allow replication connections, in the same way that
# standard_initdb does for normal connections.
sub configure_hba_for_replication
{
	my $pgdata = shift;

	open HBA, ">>$pgdata/pg_hba.conf";
	print HBA "\n# Allow replication (set up by TestLib.pm)\n";
	if (! $windows_os)
	{
		print HBA "local replication all trust\n";
	}
	else
	{
		print HBA "host replication all 127.0.0.1/32 sspi include_realm=1 map=regress\n";
	}
	close HBA;
}

my ($test_server_datadir, $test_server_logfile);


# Initialize a new cluster for testing in given directory, and start it.
sub start_test_server
{
	my ($tempdir) = @_;
	my $ret;

	print("### Starting test server in $tempdir\n");
	standard_initdb "$tempdir/pgdata";

	$ret = system_log('pg_ctl', '-D', "$tempdir/pgdata", '-w', '-l',
	  "$log_path/postmaster.log", '-o',
	  "--log-statement=all -c gp_role=utility --gp_dbid=1 --gp_contentid=-1 --logging-collector=off",
	  'start');

	if ($ret != 0)
	{
		print "# pg_ctl failed; logfile:\n";
		system('cat', "$log_path/postmaster.log");
		BAIL_OUT("pg_ctl failed");
	}

	$ENV{PGOPTIONS}      = '-c gp_session_role=utility';
	$test_server_datadir = "$tempdir/pgdata";
	$test_server_logfile = "$log_path/postmaster.log";
}

sub restart_test_server
{
	print("### Restarting test server\n");
	system_log('pg_ctl', '-D', $test_server_datadir, '-w', '-l',
	  $test_server_logfile, '-o',
	  "--log-statement=all -c gp_role=utility --gp_dbid=1 --gp_contentid=-1 --logging-collector=off",
	  'restart');
}

END
{
	if ($test_server_datadir)
	{
		system_log('pg_ctl', '-D', $test_server_datadir, '-m',
		  'immediate', 'stop');
	}
}

sub run_command
{
	my ($cmd) = @_;
	my ($stdout, $stderr);
	my $result = IPC::Run::run $cmd, '>', \$stdout, '2>', \$stderr;
	chomp($stdout);
	chomp($stderr);
	return ($stdout, $stderr);
}

sub psql
{
	my ($dbname, $sql) = @_;
	my ($stdout, $stderr);
	print("# Running SQL command: $sql\n");
	run [ 'psql', '-X', '-A', '-t', '-q', '-d', $dbname, '-f', '-' ], '<', \$sql, '>', \$stdout, '2>', \$stderr or die;
	chomp $stdout;
	$stdout =~ s/\r//g if $Config{osname} eq 'msys';
	return $stdout;
}

sub system_log
{
	print("# Running: " . join(" ", @_) ."\n");
	return system(@_);
}

sub slurp_dir
{
	my ($dir) = @_;
	opendir(my $dh, $dir)
	  or die "could not opendir \"$dir\": $!";
	my @direntries = readdir $dh;
	closedir $dh;
	return @direntries;
}

sub slurp_file
{
	my ($filename) = @_;
	local $/;
	open(my $in, '<', $filename)
	  or die "could not read \"$filename\": $!";
	my $contents = <$in>;
	close $in;
	$contents =~ s/\r//g if $Config{osname} eq 'msys';
	return $contents;
}

sub system_or_bail
{
	if (system_log(@_) != 0)
	{
		BAIL_OUT("system $_[0] failed: $?");
	}
}

sub run_log
{
	print("# Running: " . join(" ", @{$_[0]}) ."\n");
	return IPC::Run::run(@_);
}

sub issues_sql_like
{
	my ($cmd, $expected_sql, $test_name) = @_;
	truncate $test_server_logfile, 0;
	my $result = run_log($cmd);
	ok($result, "@$cmd exit code 0");
	my $log = slurp_file($test_server_logfile);
	like($log, $expected_sql, "$test_name: SQL found in server log");
}

# Generate a string made of the given range of ASCII characters
sub generate_ascii_string
{
	my ($from_char, $to_char) = @_;
	my $res;

	for my $i ($from_char .. $to_char)
	{
		$res .= sprintf("%c", $i);
	}
	return $res;
}


sub append_to_file
{
	my ($filename, $str) = @_;
	open my $fh, ">>", $filename
	  or die "could not write \"$filename\": $!";
	print $fh $str;
	close $fh;
}

#
# Test functions
#
sub command_ok
{
	my ($cmd, $test_name) = @_;
	my $result = run_log($cmd);
	ok($result, $test_name);
}

sub command_fails
{
	my ($cmd, $test_name) = @_;
	my $result = run_log($cmd);
	ok(!$result, $test_name);
}

sub command_exit_is
{
	my ($cmd, $expected, $test_name) = @_;
	print("# Running: " . join(" ", @{$cmd}) ."\n");
	my $h = start $cmd;
	$h->finish();

	# On Windows, the exit status of the process is returned directly as the
	# process's exit code, while on Unix, it's returned in the high bits
	# of the exit code (see WEXITSTATUS macro in the standard <sys/wait.h>
	# header file). IPC::Run's result function always returns exit code >> 8,
	# assuming the Unix convention, which will always return 0 on Windows as
	# long as the process was not terminated by an exception. To work around
	# that, use $h->full_result on Windows instead.
	my $result = ($Config{osname} eq "MSWin32") ?
		($h->full_results)[0] : $h->result(0);
	is($result, $expected, $test_name);
}

sub program_help_ok
{
	my ($cmd) = @_;
	my ($stdout, $stderr);
	print("# Running: $cmd --help\n");
	my $result = run [ $cmd, '--help' ], '>', \$stdout, '2>', \$stderr;
	ok($result, "$cmd --help exit code 0");
	isnt($stdout, '', "$cmd --help goes to stdout");
	is($stderr, '', "$cmd --help nothing to stderr");
}

sub program_version_ok
{
	my ($cmd) = @_;
	my ($stdout, $stderr);
	print("# Running: $cmd --version\n");
	my $result = run [ $cmd, '--version' ], '>', \$stdout, '2>', \$stderr;
	ok($result, "$cmd --version exit code 0");
	isnt($stdout, '', "$cmd --version goes to stdout");
	is($stderr, '', "$cmd --version nothing to stderr");
}

sub program_options_handling_ok
{
	my ($cmd) = @_;
	my ($stdout, $stderr);
	print("# Running: $cmd --not-a-valid-option\n");
	my $result = run [ $cmd, '--not-a-valid-option' ], '>', \$stdout, '2>',
	  \$stderr;
	ok(!$result, "$cmd with invalid option nonzero exit code");
	isnt($stderr, '', "$cmd with invalid option prints error message");
}

sub command_like
{
	my ($cmd, $expected_stdout, $test_name) = @_;
	my ($stdout, $stderr);
	print("# Running: " . join(" ", @{$cmd}) . "\n");
	my $result = run $cmd, '>', \$stdout, '2>', \$stderr;
	ok($result, "@$cmd exit code 0");
	is($stderr, '', "@$cmd no stderr");
	like($stdout, $expected_stdout, "$test_name: matches");
}

sub command_warns_like
{
	my ($cmd, $expected_stderr, $test_name) = @_;
	my ($stdout, $stderr);
	print("# Running: " . join(" ", @{$cmd}) . "\n");
	my $result = run $cmd, '>', \$stdout, '2>', \$stderr;
	ok($result, "@$cmd exit code 0");
	like($stderr, $expected_stderr, "$test_name: matches.");
}

sub command_fails_like
{
	my ($cmd, $expected_stderr, $test_name) = @_;
	my ($stdout, $stderr);

	print("# Running: " . join(" ", @{$cmd}) . "\n");
	my $result = run $cmd, '>', \$stdout, '2>', \$stderr;

	ok(!$result, "expected failure: got @$cmd exit code 0");
	like($stderr, $expected_stderr, "$test_name: not match expected stderr");
}

sub run_cmd_until
{
    my ($cmd, $desc) = @_;

    my $max_attempts = 90;
    my $attempts     = 0;
    my ($stdout, $stderr);

    while ($attempts < $max_attempts)
    {
        my $result = run $cmd, '>', \$stdout, '2>', \$stderr;
        if ($result == 1)
        {
            return 1;
        }

        # Wait a second before retrying.
        sleep 1;
        $attempts++;
    }

    # Need to format the cmd before printing since it's passed in as an array
    my $cmd_formatted =  join(" ", @{$cmd});
    # The command didn't succeed in 90 seconds
    diag qq(run_cmd_until timed out executing this command:
    $cmd_formatted
    command output:
    $stdout
    command stderr:
    $stderr
    );

    return 0;
}

sub wait_until_file_exists
{
    my ($filepath, $filedesc) = @_;
    run_cmd_until(['test', '-e', $filepath], $filedesc)
      or die "Timed out while waiting for $filedesc $filepath";
}

1;
