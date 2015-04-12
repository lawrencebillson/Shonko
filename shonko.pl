#!/usr/bin/perl
# Script to read XML exports from Fluke Linkware, attempt to detect fraudulent
# cable test results
# 
# Lawrence Billson, 2015
#
# Usage: ./shonko.pl <folder for export>
# 
# Threshold values
#
# Time delta - it takes at least 30 seconds to take a cable measurement with a DTX or DSP tester
# Anything shorter than 10 seconds is highly suspect. Also, when values are coppied from one 
# report to another, the timestamps are generally preserved
# $deltat = <time in seconds> 
$deltat = 10;
#
# Length compare value - if the lengths are wildly different, it's unlikely to be a duplicate cable
# Unfortunately, this is measured in feet - what a dumb arse unit, if either of the below 
# threshold is met, we'll take a closer look at the cable
#
# Delta len, say 5 feet
$deltalen = -100;
# Percent compare value, say 5% 
$deltapercent = 5;

# Signature comparison
# This is the most contravercial bit - the program takes two signatures, a sum of the PSNEXT values,
# and the PSELFEXT frequencies. The cable signature is the sum of these values - this seems to differentiate
# between deliberate duplicates
# 
# For reference, my 'known good' sample size was fairly small, but it included cables that were installed in two
# vehicles. Each vehicle had two cables running to each of about four locations. These were installed by the same
# person. In all cases the lengths, return loss and various other factors were identical. These values still were
# able to see a large gulf between these results, and some deliberate duplications
#
# 
# I suggest a value of less than 10 is almost certainly a deliberate (or maybe, but probably not) duplication
# A value of 20 needs investigation
# A value of more than 100 is almost certainly a different cable
$fakeval = 20;

# Do you want lots of diagnostics?
$diag = 1;

# Working parts below
#
use Time::Local;

# Read the import file, make a hash of our input files
open(INDEX,"$ARGV[0]/index.xml") or  die $!;
while ($line = <INDEX>) {
	@xmlparts = split(/[<>]/,$line);
	chomp($line);
	if ($line =~ '<CableID>') {
		$id = $xmlparts[2];
		}
	if ($line =~ '<FileName>') {
		$filename{$id} = "$ARGV[0]/$xmlparts[2].xml";
		}
	}
close(INDEX);		

# Read the xml data dumps, build a hash table with values we want to start comparing
#
# 
foreach $report (sort keys %filename) {
	# Open the file
	open(REPIN,$filename{$report}) or die $!;
	while ($rline = <REPIN>) {
		chomp $rline;
		@xmlparts = split(/[<>]/,$rline);
		
		# What data do we care about? - Date and Time for one, too easy to duplicate in software
		if ($rline =~ '<Date>') {
			$date = $xmlparts[2];
			}
		if ($rline =~ '<Time>') {
			$time = $xmlparts[2];
			# We can now do some processing, turn it into a UNIX time, then store it
			# Remove all of the whitespace
			$time =~ s/^\s+//;
			($month,$day,$year) = split('/',$date);
			($hour,$min,$sec) = split(/[:P]/,$time);

			$db{$report}{'exectime'} = timelocal($sec,$min,$hour,$day,$month,$year);
			}

		# Length is super important
		if ($rline =~ '<LengthFeet>') {
			$db{$report}{'length'} = $xmlparts[2];
			}

		# Things that might be indicators that the same cable is being retested
		# 
	
		# Are we inside, or outside the PSNEXT tag?	
		if ($rline =~ '<PSNEXT>') {
			$psnext = 1;
			}
		
		
		# If we're inside PSNEXT, just add up the MarginValue values, 
		if (($psnext) && ($rline =~ 'MarginValue')) {
			$db{$report}{'psnextmarginval'} += $xmlparts[2];
			}
		
		if ($rline =~ '<\/PSNEXT>') {
			$psnext = 0;
			}


		# Same trick again for PSELFEXT
		# Are we inside, or outside the PSELFEXT tag?	
		if ($rline =~ '<PSELFEXT>') {
			$pselfext = 1;
			}
		
		if (($pselfext) && ($rline =~ 'MarginFrequency')) {
			$db{$report}{'pselfextfreq'} += $xmlparts[2];
			}
		
		if ($rline =~ '<\/PSELFEXT>') {
			$pselfext = 0;
			}

		}
		

	close(REPIN);
	}

# We've collected some data, let's do post processing
# 
# Do we have any times that don't look right?
#
print "Phase 1 - Checking for duplicate or illegal time events\n"; 
foreach $thost (sort keys %db) {

	# Cycle through the other hosts
	foreach $otherhost (sort keys %db) {
		
		# Are we comparing against ourselves
		if ($thost ne $otherhost) {
			$delta = abs($db{$thost}{'exectime'} - $db{$otherhost}{'exectime'});
			if ($delta <= $deltat) {
				print "\tWARNING $thost and $otherhost have delta of $delta (Threshold $deltat)\n";
				}
			}
		}
	}

# Look at the lengths, if they're within our threshold we will shove them into an array
print "Phase 2 - Comparing lengths\n";
foreach $thost (sort keys %db) {
	# Cycle through the other hosts
	foreach $otherhost (sort keys %db) {
		# Are we comparing against ourselves
		if ($thost ne $otherhost) {
			$delta = abs($db{$thost}{'length'} - $db{$otherhost}{'length'});
			# Is it within the number of feet?
			if ($delta <= $deltalen) {
				if (!$suspect{$otherhost}{$thost}) {
			   		if ($diag) { 
			   			print "\tNotice:  Absolute length $thost is $db{$thost}{'length'} close to $otherhost $db{$otherhost}{'length'} (Measured $delta, Threshold $deltalen)\n";
						}
					$suspect{$thost}{$otherhost} = 1;
					}
				}
			else {
				# Second chance to catch the shonky stuff, is it within our percentage range?
				$percentlen = ($delta / $db{$thost}{'length'}) * 100;
				if ($percentlen <= $deltapercent) {
					if (!$suspect{$otherhost}{$thost}) {
						if ($diag) { 
			   				print "\tNotice:  Relative length $thost is $db{$thost}{'length'} close to $otherhost $db{$otherhost}{'length'} (Measured $percentlen, Threshold $deltapercent%)\n";
							}
						$suspect{$thost}{$otherhost} = 1;
						}
					}
				}
			}
		}
	}

print "Phase 3 - examining signatures for cables that are close in length\n";
foreach $sus (sort keys %suspect) {
	# Break each into pairs
	foreach $susp (sort keys %{ $suspect{$sus} } ) {

		# Signature one delta
		$asig = abs($db{$sus}{'psnextmarginval'} - $db{$susp}{'psnextmarginval'});

		#Signature two
		$bsig = abs($db{$sus}{'pselfextfreq'} - $db{$susp}{'pselfextfreq'});

		# Add them - this weeds out cables that are similar length, but actually different cables
		$dsig = $asig + $bsig;
	
		if ($diag) {
			print "\tComparing signatures for $sus with $susp - $dsig\n";
			}
		
		if ($dsig <= $fakeval) {
			print "\t\tWARNING: Duplicate cable signature detected - $sus and $susp - Signature difference is $dsig\n"
			}
		}
	}


print "Done\n";	
