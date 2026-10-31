#!/bin/zsh
# Run every netlist here through ngspice and write what it answers into
# sh/sysl/amber/tests_oracle.sysl, a test per netlist holding amber to ngspice's numbers.
#
#     oracle/generate.zsh
#
# Each netlist carries a `.control` block (which amber skips) that tightens ngspice's tolerances, runs
# the analysis, puts a run through time on its print step with `linearize`, and writes the vectors it
# names with `wrdata`. The vectors' names come from that `wrdata` line. The tests need no ngspice: the
# numbers are written into them, and this script is only rerun when a netlist here changes.

set -e

here=${0:A:h}
out=$here/../sh/sysl/amber/tests_oracle.sysl
work=$(mktemp -d)

{
  print 'module sh.sysl.amber'
  print '@tests'
  print
  print '// amber against ngspice, on the netlists in oracle/: written by oracle/generate.zsh, not by hand.'
  print '//'
  print "// $(ngspice -v 2>/dev/null | grep -m1 -o 'ngspice-[0-9.]*') with reltol 1e-6 is the reference, so the difference is"
  print '// amber'\''s own error.'

  for cir in $here/*.cir; do
    name=${cir:t:r}
    title=$(head -1 $cir)
    vectors=$(grep -m1 '^wrdata' $cir | cut -d' ' -f3-)

    cp $cir $work/
    (cd $work && ngspice -b ${cir:t} > /dev/null 2>&1)

    print
    print "@test(\"ngspice: ${title:l}\")"
    print "oracle_${name}()"
    print "    val netlist = \"\"\""
    sed 's/^/        /' $cir
    print "        \"\"\""
    quoted=()
    for v in ${=vectors}; do quoted+=("\"$v\""); done
    print "    val names = [${(j:, :)quoted}]"
    print '    val expected = ['
    # Each row of a `wrdata` file is the scale and a value, once for every vector: the scale is
    # kept once, then the values.
    awk '{ printf "        "; printf "%s", $1; for (i = 2; i <= NF; i += 2) printf ", %s", $i; print "," }' $work/$name.data
    print '    ]'
    print
    print '    agree(parse_netlist(netlist).unwrap(), names, expected[..])'
  done
} > $out.new

mv $out.new $out
rm -rf $work
print "wrote ${out:A}"
