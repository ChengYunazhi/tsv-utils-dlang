#! /bin/sh

if [ $# -le 1 ]; then
    echo "Insufficient arguments. A program name and output director are required."
    exit 1
fi

prog=$1
shift
odir=$1
echo "Testing ${prog}, output to ${odir}"

## Three args: program, args, output file
runtest () {
    echo "" >> $3
    echo "====[tsv-uniq $2]====" >> $3
    $1 $2 >> $3 2>&1
    return 0
}

## Note: input1.tsv has duplicate values in fields 2 & 3. Tests with those fields
## as keys that have append values need to use --allow-duplicate-keys (unless
## testing error handling).

basic_tests_1=${odir}/basic_tests_1.txt

echo "Basic tests set 1" > ${basic_tests_1}
echo "-----------------" >> ${basic_tests_1}

# Whole line as key
echo "====Whole line as key===" >> ${basic_tests_1}
runtest ${prog} "input1.tsv" ${basic_tests_1}
runtest ${prog} "--header input1.tsv" ${basic_tests_1}
runtest ${prog} "-f 0 input1.tsv" ${basic_tests_1}
runtest ${prog} "--header -f 0 input1.tsv" ${basic_tests_1}
runtest ${prog} "--header -f 1,2,3,4,5 input1.tsv" ${basic_tests_1}
runtest ${prog} "--header -f 1-5 input1.tsv" ${basic_tests_1}
runtest ${prog} "--header --ignore-case input1.tsv" ${basic_tests_1}
runtest ${prog} "--ignore-case --equiv input1.tsv" ${basic_tests_1}
runtest ${prog} "--header --equiv --ignore-case input1.tsv" ${basic_tests_1}
runtest ${prog} "--header --equiv --equiv-header id --ignore-case input1.tsv" ${basic_tests_1}

# Individual keys
echo "" >> ${basic_tests_1}; echo "====Individual keys===" >> ${basic_tests_1}
runtest ${prog} "input1.tsv --fields 1" ${basic_tests_1}
runtest ${prog} "input1.tsv --header -f 2" ${basic_tests_1}
runtest ${prog} "input1.tsv --header -f 3,4" ${basic_tests_1}
runtest ${prog} "input1.tsv --header -f 4,3" ${basic_tests_1}
runtest ${prog} "input1.tsv --header -f 4-3" ${basic_tests_1}
runtest ${prog} "input1.tsv --header -f 3,4 --ignore-case" ${basic_tests_1}
runtest ${prog} "input1.tsv --header -f 5" ${basic_tests_1}
runtest ${prog} "input1.tsv --header -f 3,4 --equiv --ignore-case" ${basic_tests_1}
runtest ${prog} "input1.tsv -H -f 3,4 --equiv --ignore-case" ${basic_tests_1}
runtest ${prog} "input1.tsv --header -f 3,4 --equiv --equiv-start 10 --ignore-case" ${basic_tests_1}
runtest ${prog} "input1.tsv --header -f 3,4 --equiv --equiv-start 10 --equiv-header id --ignore-case" ${basic_tests_1}

# Max unique values
echo "" >> ${basic_tests_1}; echo "====Max count tests===" >> ${basic_tests_1}
runtest ${prog} "-H --max 0 input1.tsv" ${basic_tests_1}
runtest ${prog} "-H --max 1 input1.tsv" ${basic_tests_1}
runtest ${prog} "-H --max 2 input1.tsv" ${basic_tests_1}
runtest ${prog} "-H -m 3 input1.tsv input1.tsv" ${basic_tests_1}
runtest ${prog} "-H -m 2 input1.tsv input1.tsv input1.tsv" ${basic_tests_1}
runtest ${prog} "-H -f 2 --max 3 input2.tsv input2.tsv" ${basic_tests_1}
runtest ${prog} "-H -f 3,5 --max 3 input2.tsv input2.tsv" ${basic_tests_1}
runtest ${prog} "-H -f 2 --equiv --max 3 input2.tsv input2.tsv" ${basic_tests_1}

echo "" >> ${basic_tests_1}; echo "====repeated and at-least count tests===" >> ${basic_tests_1}
runtest ${prog} "--repeated input1.tsv" ${basic_tests_1}
runtest ${prog} "-H --repeated input1.tsv" ${basic_tests_1}
runtest ${prog} "-H --at-least 0 input1.tsv" ${basic_tests_1}
runtest ${prog} "-H --at-least 1 input1.tsv" ${basic_tests_1}
runtest ${prog} "-H --at-least 2 input1.tsv" ${basic_tests_1}
runtest ${prog} "-H --at-least 3 input1.tsv" ${basic_tests_1}
runtest ${prog} "--at-least 3 input1.tsv" ${basic_tests_1}
runtest ${prog} "-H -a 3 input1.tsv input1.tsv" ${basic_tests_1}
runtest ${prog} "-H -r input1.tsv input1.tsv input1.tsv" ${basic_tests_1}
runtest ${prog} "-H -f 2 -r input2.tsv input2.tsv" ${basic_tests_1}
runtest ${prog} "-H -f 2 --at-least 3 input2.tsv input2.tsv" ${basic_tests_1}
runtest ${prog} "-H -f 3,5 --at-least 2 input2.tsv input2.tsv" ${basic_tests_1}
runtest ${prog} "-H -f 2 --equiv --repeated input2.tsv input2.tsv input2.tsv" ${basic_tests_1}
runtest ${prog} "-H -f 2 --equiv --at-least 3 input2.tsv input2.tsv input2.tsv" ${basic_tests_1}

runtest ${prog} "-H --repeated --max 0 input1.tsv" ${basic_tests_1}
runtest ${prog} "-H --repeated --max 1 input1.tsv" ${basic_tests_1}
runtest ${prog} "-H --r --max 2 input1.tsv" ${basic_tests_1}
runtest ${prog} "-H --r --max 3 input1.tsv" ${basic_tests_1}
runtest ${prog} "-H --r --max 3 input1.tsv input1.tsv" ${basic_tests_1}
runtest ${prog} "-H --at-least 2 --max 2 input1.tsv" ${basic_tests_1}
runtest ${prog} "-H --at-least 3 --max 0 input1.tsv" ${basic_tests_1}
runtest ${prog} "-H --at-least 3 --max 1 input1.tsv" ${basic_tests_1}
runtest ${prog} "-H --at-least 3 --max 2 input1.tsv" ${basic_tests_1}
runtest ${prog} "-H --at-least 3 --max 3 input1.tsv" ${basic_tests_1}
runtest ${prog} "-H --at-least 3 --max 4 input1.tsv input1.tsv input1.tsv" ${basic_tests_1}
runtest ${prog} "-H --at-least 3 --max 5 input1.tsv input1.tsv input1.tsv" ${basic_tests_1}
runtest ${prog} "-H -f 2 -r  --max 4 input2.tsv input2.tsv" ${basic_tests_1}
runtest ${prog} "-H -f 2 --at-least 3 --max 4 input2.tsv input2.tsv" ${basic_tests_1}
runtest ${prog} "-H -f 3,5 --at-least 2 --max 4 input2.tsv input2.tsv" ${basic_tests_1}
runtest ${prog} "-H -f 2 --equiv --at-least 3 --max 5 input2.tsv input2.tsv input2.tsv" ${basic_tests_1}

# Alternate delimiter tests
echo "" >> ${basic_tests_1}; echo "====Alternate delimiter tests===" >> ${basic_tests_1}
runtest ${prog} "input_delim_underscore.tsv --delimiter _ --fields 1" ${basic_tests_1}
runtest ${prog} "input_delim_underscore.tsv --delimiter _ --header -f 2" ${basic_tests_1}
runtest ${prog} "input_delim_underscore.tsv -d _ --header -f 3,4" ${basic_tests_1}
runtest ${prog} "input_delim_underscore.tsv -d _ --header -f 3,4 --equiv --ignore-case" ${basic_tests_1}
runtest ${prog} "input_delim_underscore.tsv -d _ --header -f 3,4 --equiv --equiv-start 10 --equiv-header id --ignore-case" ${basic_tests_1}

# Multi-file and standard input tests
echo "" >> ${basic_tests_1}; echo "====Multi-file and standard input tests===" >> ${basic_tests_1}
runtest ${prog} "input1.tsv input2.tsv" ${basic_tests_1}
runtest ${prog} "--header -f 3,4 input1.tsv input2.tsv" ${basic_tests_1}

## runtest can't do these. Generate them directly.
echo "" >> ${basic_tests_1}; echo "====[cat input1.tsv input2.tsv | tsv-uniq]====" >> ${basic_tests_1}
cat input1.tsv input2.tsv | ${prog} >> ${basic_tests_1} 2>&1

echo "" >> ${basic_tests_1}; echo "====[cat input1.tsv | tsv-uniq --header -f 3,4 -- - input2.tsv]====" >> ${basic_tests_1}
cat input1.tsv | ${prog} --header -f 3,4 -- - input2.tsv >> ${basic_tests_1} 2>&1

## Help and Version printing

echo "" >> ${basic_tests_1}
echo "Help and Version printing 1" >> ${basic_tests_1}
echo "-----------------" >> ${basic_tests_1}
echo "" >> ${basic_tests_1}

echo "====[tsv-uniq --help | grep -c Synopsis]====" >> ${basic_tests_1}
${prog} --help 2>&1 | grep -c Synopsis >> ${basic_tests_1} 2>&1

echo "====[tsv-uniq --help-verbose | grep -c Synopsis]====" >> ${basic_tests_1}
${prog} --help-verbose 2>&1 | grep -c Synopsis >> ${basic_tests_1} 2>&1

echo "====[tsv-uniq --version | grep -c 'tsv-uniq (eBay/tsv-utils-dlang)']====" >> ${basic_tests_1}
${prog} --version 2>&1 | grep -c 'tsv-uniq (eBay/tsv-utils-dlang)' >> ${basic_tests_1} 2>&1

echo "====[tsv-uniq -V | grep -c 'tsv-uniq (eBay/tsv-utils-dlang)']====" >> ${basic_tests_1}
${prog} -V 2>&1 | grep -c 'tsv-uniq (eBay/tsv-utils-dlang)' >> ${basic_tests_1} 2>&1

## Error cases

error_tests_1=${odir}/error_tests_1.txt

echo "Error test set 1" > ${error_tests_1}
echo "----------------" >> ${error_tests_1}

runtest ${prog} "-f 1,0 input1.tsv" ${error_tests_1}

# Disable this test until Phobos 2.071 is available on all compilers
# 2.071 changed the error message in a minor way.
runtest ${prog} "-f 1,g input1.tsv" ${error_tests_1}

runtest ${prog} "-f 1-g input1.tsv" ${error_tests_1}
runtest ${prog} "-f 0-2 input1.tsv" ${error_tests_1}
runtest ${prog} "-f 1- input1.tsv" ${error_tests_1}

runtest ${prog} "-d abc -f 2 input1.tsv" ${error_tests_1}
runtest ${prog} "-d ß -f 1 input1.tsv" ${error_tests_1}
runtest ${prog} "-f 2 --equiv-start 10 input1.tsv" ${error_tests_1}
runtest ${prog} "-f 2 --equiv-header abc input1.tsv" ${error_tests_1}
runtest ${prog} "-f 2,30 input1.tsv" ${error_tests_1}
runtest ${prog} "-f 2-30 input1.tsv" ${error_tests_1}

exit $?
