/**
Command line tool that filters TSV files.

This tool filters tab-delimited files based on numeric or string comparisons
against specific fields. See the helpText string for details.

Copyright (c) 2015-2018, eBay Software Foundation
Initially written by Jon Degenhardt

License: Boost Licence 1.0 (http://boost.org/LICENSE_1_0.txt)
*/
module tsv_filter;

import std.algorithm : canFind, equal, findSplit, max, min;
import std.conv : to;
import std.format : format;
import std.math : abs, isFinite, isInfinity, isNaN;
import std.regex;
import std.stdio;
import std.string : isNumeric;
import std.typecons : tuple;
import std.uni: asLowerCase, toLower;

/* The program has two main parts, command line arg processing and processing the input
 * files. Much of the work is in command line arg processing. This sets up the tests run
 * against each input line. The tests are an array of delegates (closures) run against the
 * fields in the line. The tests are based on command line arguments, of which there is
 * a lengthy set, one for each test.
 */

int main(string[] cmdArgs)
{
    /* When running in DMD code coverage mode, turn on report merging. */
    version(D_Coverage) version(DigitalMars)
    {
        import core.runtime : dmd_coverSetMerge;
        dmd_coverSetMerge(true);
    }

    TsvFilterOptions cmdopt;
    auto r = cmdopt.processArgs(cmdArgs);
    if (!r[0]) return r[1];
    version(LDC_Profile)
    {
        import ldc.profile : resetAll;
        resetAll();
    }
    try tsvFilter(cmdopt, cmdArgs[1..$]);
    catch (Exception exc)
    {
        stderr.writefln("Error [%s]: %s", cmdopt.programName, exc.msg);
        return 1;
    }
    return 0;
}

auto helpText = q"EOS
Synopsis: tsv-filter [options] [file...]

Filter tab-delimited files for matching lines via comparison tests against
individual fields. Use '--help-verbose' for a more detailed description.

Global options:
  --help-verbose      Print full help.
  --help-options      Print the options list by itself.
  --V|version         Print version information and exit.
  --H|header          Treat the first line of each file as a header.
  --or                Evaluate tests as an OR rather than an AND clause.
  --v|invert          Invert the filter, printing lines that do not match.
  --d|delimiter CHR   Field delimiter. Default: TAB.

Operators:
* Test if a field is empty (no characters) or blank (empty or whitespace only).
  Syntax:  --empty|not-empty|blank|not-blank  FIELD
  Example: --empty 5          // True if field 5 is empty

* Test if a field is numeric, finite, NaN, or infinity
  Syntax:  --is-numeric|is-finite|is-nan|is-infinity FIELD
  Example: --is-numeric 5 --gt 5:100  // Ensure field 5 is numeric before --gt test.

* Compare a field to a number (integer or float)
  Syntax:  --eq|ne|lt|le|gt|ge  FIELD:NUM
  Example: --lt 5:1000 --gt 2:0.5  // True if (field 5 < 1000) and (field 2 > 0.5)

* Compare a field to a string
  Syntax:  --str-eq|str-ne  FIELD:STR
  Example: --str-eq 3:abc        // True if field 3 is "abc"

* Test if a field contains a string (substring search)
  Syntax:  --str-in-fld|str-not-in-fld|istr-in-fld|istr-not-in-fld  FIELD:STR
  Example: --str-in-fld 1:hello  // True if field 1 contains "hello"

* Test if a field matches a regular expression.
  Syntax:  --regex|iregex|not-regex|not-iregex  FIELD:REGEX
  Example: --regex '3:ab*c'      // True if field 3 contains "ac", "abc", "abbc", etc.

* Field to field comparisons - Similar to field vs literal comparisons, but field vs field.
  Syntax:  --ff-eq|ff-ne|ff-lt|ff-le|ff-gt|ff-ge  FIELD1:FIELD2
           --ff-str-eq|ff-str-ne|ff-istr-eq|ff-istr-ne  FIELD1:FIELD2
  Example: --ff-eq 2:4           // True if fields 2 and 4 are numerically equivalent
           --ff-str-eq 2:4       // True if fields 2 and 4 are the same strings

* Field to field difference comparisons - Absolute and relative difference
  Syntax:  --ff-absdiff-le|ff-absdiff-gt FIELD1:FIELD2:NUM
           --ff-reldiff-le|ff-reldiff-gt FIELD1:FIELD2:NUM
  Example: --ff-absdiff-lt 1:3:0.25   // True if abs(field1 - field2) < 0.25

EOS";

auto helpTextVerbose = q"EOS
Synopsis: tsv-filter [options] [file...]

Filter lines of tab-delimited files via comparison tests against fields. Multiple
tests can be specified, by default they are evaluated as AND clause. Lines
satisfying the tests are written to standard output.

Typical test syntax is '--op field:value', where 'op' is an operator, 'field' is a
1-based field index, and 'value' is the comparison basis. For example, '--lt 3:500'
tests if field 3 is less than 500. A more complete example:

  tsv-filter --header --gt 1:50 --lt 1:100 --le 2:1000 data.tsv

This outputs all lines from file data.tsv where field 1 is greater than 50 and less
than 100, and field 2 is less than or equal to 1000. The header is also output.

Tests available include:
  * Test if a field is empty (no characters) or blank (empty or whitespace only).
  * Test if a field is interpretable as a number, a finite number, NaN, or Infinity.
  * Compare a field to a number - Numeric equality and relational tests.
  * Compare a field to a string - String equality and relational tests.
  * Test if a field matches a regular expression. Case sensitive or insensitive.
  * Test if a field contains a string. Sub-string search, case sensitive or insensitive.
  * Field to field comparisons - Similar to the other tests, except comparing
    one field to another in the same line.

Details:
  * The run is aborted if there are not enough fields in an input line.
  * Numeric tests will fail and abort the run if a field cannot be interpreted as a
    number. This includes fields with no text. To avoid this use '--is-numeric' or
    '--is-finite' prior to the numeric test. For example, '--is-numeric 5 --gt 5:100'
    ensures field 5 is numeric before running the --gt test.
  * Regular expression syntax is defined by the D programming language. They follow
    common conventions (perl, python, etc.). Most common forms work as expected.

Options:
EOS";

auto helpTextOptions = q"EOS
Synopsis: tsv-filter [options] [file...]

Options:
EOS";

/**
The next blocks of code define the structure of the boolean tests run against input lines.
This includes function and delegate (closure) signatures, creation mechanisms, option
handlers, etc. Command line arg processing to build the test structure.
*/

/* FieldsPredicate delegate signature - Each input line is run against a set of boolean
 * tests. Each test is a 'FieldsPredicate'. A FieldsPredicate is a delegate (closure)
 * containing all info about the test except the field values of the line being tested.
 * These delegates are created as part of command line arg processing. The wrapped data
 * includes operation, field indexes, literal values, etc. At run-time the delegate is
 * passed one argument, the split input line.
 */
alias FieldsPredicate = bool delegate(const char[][] fields);

/* FieldsPredicate function signatures - These aliases represent the different function
 * signatures used in FieldsPredicate delegates. Each alias has a corresponding 'make'
 * function. The 'make' function takes a real predicate function and closure args and
 * returns a FieldsPredicate delegate. Predicates types are:
 *
 * - FieldUnaryPredicate - Test based on a single field. (e.g. --empty 4)
 * - FieldVsNumberPredicate - Test based on a field index (used to get the field value)
 *   and a fixed numeric value. For example, field 2 less than 100 (--lt 2:100).
 * - FieldVsStringPredicate - Test based on a field and a string. (e.g. --str-eq 2:abc)
 * - FieldVsIStringPredicate - Case-insensitive test based on a field and a string.
 *   (e.g. --istr-eq 2:abc)
 * - FieldVsRegexPredicate - Test based on a field and a regex. (e.g. --regex '2:ab*c')
 * - FieldVsFieldPredicate - Test based on two fields. (e.g. --ff-le 2:4).
 *
 * An actual FieldsPredicate takes the fields from the line and the closure args and
 * runs the test. For example, a function testing if a field is less than a specific
 * value would pull the specified field from the fields array, convert the string to
 * a number, then run the less-than test.
 */
alias FieldUnaryPredicate    = bool function(const char[][] fields, size_t index);
alias FieldVsNumberPredicate = bool function(const char[][] fields, size_t index, double value);
alias FieldVsStringPredicate = bool function(const char[][] fields, size_t index, string value);
alias FieldVsIStringPredicate = bool function(const char[][] fields, size_t index, dstring value);
alias FieldVsRegexPredicate  = bool function(const char[][] fields, size_t index, Regex!char value);
alias FieldVsFieldPredicate  = bool function(const char[][] fields, size_t index1, size_t index2);
alias FieldFieldNumPredicate  = bool function(const char[][] fields, size_t index1, size_t index2, double value);

FieldsPredicate makeFieldUnaryDelegate(FieldUnaryPredicate fn, size_t index)
{
    return fields => fn(fields, index);
}

FieldsPredicate makeFieldVsNumberDelegate(FieldVsNumberPredicate fn, size_t index, double value)
{
    return fields => fn(fields, index, value);
}

FieldsPredicate makeFieldVsStringDelegate(FieldVsStringPredicate fn, size_t index, string value)
{
    return fields => fn(fields, index, value);
}

FieldsPredicate makeFieldVsIStringDelegate(FieldVsIStringPredicate fn, size_t index, dstring value)
{
    return fields => fn(fields, index, value);
}

FieldsPredicate makeFieldVsRegexDelegate(FieldVsRegexPredicate fn, size_t index, Regex!char value)
{
    return fields => fn(fields, index, value);
}

FieldsPredicate makeFieldVsFieldDelegate(FieldVsFieldPredicate fn, size_t index1, size_t index2)
{
    return fields => fn(fields, index1, index2);
}

FieldsPredicate makeFieldFieldNumDelegate(FieldFieldNumPredicate fn, size_t index1, size_t index2, double value)
{
    return fields => fn(fields, index1, index2, value);
}

/* Predicate functions - These are the actual functions used in a FieldsPredicate. They
 * are a direct reflection of the operators available via command line args. Each matches
 * one of the FieldsPredicate function aliases defined above.
 */
bool fldEmpty(const char[][] fields, size_t index) { return fields[index].length == 0; }
bool fldNotEmpty(const char[][] fields, size_t index) { return fields[index].length != 0; }
bool fldBlank(const char[][] fields, size_t index) { return cast(bool) fields[index].matchFirst(ctRegex!`^\s*$`); }
bool fldNotBlank(const char[][] fields, size_t index) { return !fields[index].matchFirst(ctRegex!`^\s*$`); }

bool fldIsNumeric(const char[][] fields, size_t index) { return fields[index].isNumeric; }
bool fldIsFinite(const char[][] fields, size_t index) { return fields[index].isNumeric && fields[index].to!double.isFinite; }
bool fldIsNaN(const char[][] fields, size_t index) { return fields[index].isNumeric && fields[index].to!double.isNaN; }
bool fldIsInfinity(const char[][] fields, size_t index) { return fields[index].isNumeric && fields[index].to!double.isInfinity; }

bool numLE(const char[][] fields, size_t index, double val) { return fields[index].to!double <= val; }
bool numLT(const char[][] fields, size_t index, double val) { return fields[index].to!double  < val; }
bool numGE(const char[][] fields, size_t index, double val) { return fields[index].to!double >= val; }
bool numGT(const char[][] fields, size_t index, double val) { return fields[index].to!double  > val; }
bool numEQ(const char[][] fields, size_t index, double val) { return fields[index].to!double == val; }
bool numNE(const char[][] fields, size_t index, double val) { return fields[index].to!double != val; }

bool strLE(const char[][] fields, size_t index, string val) { return fields[index] <= val; }
bool strLT(const char[][] fields, size_t index, string val) { return fields[index]  < val; }
bool strGE(const char[][] fields, size_t index, string val) { return fields[index] >= val; }
bool strGT(const char[][] fields, size_t index, string val) { return fields[index]  > val; }
bool strEQ(const char[][] fields, size_t index, string val) { return fields[index] == val; }
bool strNE(const char[][] fields, size_t index, string val) { return fields[index] != val; }
bool strInFld(const char[][] fields, size_t index, string val) { return fields[index].canFind(val); }
bool strNotInFld(const char[][] fields, size_t index, string val) { return !fields[index].canFind(val); }

/* Note: For istr predicates, the command line value has been lower-cased by fieldVsIStringOptionHander.
 */
bool istrEQ(const char[][] fields, size_t index, dstring val) { return fields[index].asLowerCase.equal(val); }
bool istrNE(const char[][] fields, size_t index, dstring val) { return !fields[index].asLowerCase.equal(val); }
bool istrInFld(const char[][] fields, size_t index, dstring val) { return fields[index].asLowerCase.canFind(val); }
bool istrNotInFld(const char[][] fields, size_t index, dstring val) { return !fields[index].asLowerCase.canFind(val); }

/* Note: Case-sensitivity is built into the regex value, so these regex predicates are
 * used for both case-sensitive and case-insensitive regex operators.
 */
bool regexMatch(const char[][] fields, size_t index, Regex!char val) { return cast(bool) fields[index].matchFirst(val); }
bool regexNotMatch(const char[][] fields, size_t index, Regex!char val) { return !fields[index].matchFirst(val); }

bool ffLE(const char[][] fields, size_t index1, size_t index2) { return fields[index1].to!double <= fields[index2].to!double; }
bool ffLT(const char[][] fields, size_t index1, size_t index2) { return fields[index1].to!double  < fields[index2].to!double; }
bool ffGE(const char[][] fields, size_t index1, size_t index2) { return fields[index1].to!double >= fields[index2].to!double; }
bool ffGT(const char[][] fields, size_t index1, size_t index2) { return fields[index1].to!double  > fields[index2].to!double; }
bool ffEQ(const char[][] fields, size_t index1, size_t index2) { return fields[index1].to!double == fields[index2].to!double; }
bool ffNE(const char[][] fields, size_t index1, size_t index2) { return fields[index1].to!double != fields[index2].to!double; }
bool ffStrEQ(const char[][] fields, size_t index1, size_t index2) { return fields[index1] == fields[index2]; }
bool ffStrNE(const char[][] fields, size_t index1, size_t index2) { return fields[index1] != fields[index2]; }
bool ffIStrEQ(const char[][] fields, size_t index1, size_t index2)
{
    return equal(fields[index1].asLowerCase, fields[index2].asLowerCase);
}
bool ffIStrNE(const char[][] fields, size_t index1, size_t index2)
{
    return !equal(fields[index1].asLowerCase, fields[index2].asLowerCase);
}

auto AbsDiff(double v1, double v2) { return (v1 - v2).abs; }
auto RelDiff(double v1, double v2) { return (v1 - v2).abs / min(v1.abs, v2.abs); }

bool ffAbsDiffLE(const char[][] fields, size_t index1, size_t index2, double value)
{
    return AbsDiff(fields[index1].to!double, fields[index2].to!double) <= value;
}
bool ffAbsDiffGT(const char[][] fields, size_t index1, size_t index2, double value)
{
    return AbsDiff(fields[index1].to!double, fields[index2].to!double) > value;
}
bool ffRelDiffLE(const char[][] fields, size_t index1, size_t index2, double value)
{
    return RelDiff(fields[index1].to!double, fields[index2].to!double) <= value;
}
bool ffRelDiffGT(const char[][] fields, size_t index1, size_t index2, double value)
{
    return RelDiff(fields[index1].to!double, fields[index2].to!double) > value;
}

/* Command line option handlers - There is a command line option handler for each
 * predicate type. That is, one each for FieldUnaryPredicate, FieldVsNumberPredicate,
 * etc. Option handlers are passed the tests array, the predicate function, and the
 * command line option arguments. A FieldsPredicate delegate is created and appended to
 * the tests array. An exception is thrown if errors are detected while processing the
 * option, the error text is intended for the end user.
 *
 * These option handlers have similar functionality, differing in option processing and
 * error message generation. fieldVsNumberOptionHandler is described as an example. It
 * handles command options such as '--lt 3:1000', which tests field 3 for a values less
 * than 1000. It is passed the tests array, the 'numLE' function to use for the test, and
 * the string "3:1000" representing the option value. It parses the option value into
 * field index (unsigned int) and value (double). These are wrapped in a FieldsPredicate
 * which is added to the tests array. An error is signaled if the option string is invalid.
 *
 * During processing, fields indexes are converted from one-based to zero-based. As an
 * optimization, the maximum field index is also tracked. This allows early termination of
 * line splitting.
 */

void fieldUnaryOptionHandler(
    ref FieldsPredicate[] tests, ref size_t maxFieldIndex, FieldUnaryPredicate fn, string option, string optionVal)
{
    size_t field;
    try field = optionVal.to!size_t;
    catch (Exception exc)
    {
        throw new Exception(
            format("Invalid value in option: '--%s %s'. Expected: '--%s <field>' where field is a 1-upped integer.",
                   option, optionVal, option));
    }

    if (field == 0)
    {
        throw new Exception(
            format("Invalid option: '--%s %s'. Zero is not a valid field index.", option, optionVal));
    }

    size_t zeroBasedIndex = field - 1;
    tests ~= makeFieldUnaryDelegate(fn, zeroBasedIndex);
    maxFieldIndex = (zeroBasedIndex > maxFieldIndex) ? zeroBasedIndex : maxFieldIndex;
}

void fieldVsNumberOptionHandler(
    ref FieldsPredicate[] tests, ref size_t maxFieldIndex, FieldVsNumberPredicate fn, string option, string optionVal)
{
    auto valSplit = findSplit(optionVal, ":");
    if (valSplit[1].length == 0 || valSplit[2].length == 0)
    {
        throw new Exception(
            format("Invalid option: '%s %s'. Expected: '%s <field>:<val>' where <field> and <val> are numbers.",
                   option, optionVal, option));
    }
    size_t field;
    double value;
    try
    {
        field = valSplit[0].to!size_t;
        value = valSplit[2].to!double;
    }
    catch (Exception exc)
    {
        throw new Exception(
            format("Invalid numeric values in option: '--%s %s'. Expected: '--%s <field>:<val>' where <field> and <val> are numbers.",
                   option, optionVal, option));
    }

    if (field == 0)
    {
        throw new Exception(
            format("Invalid option: '--%s %s'. Zero is not a valid field index.", option, optionVal));
    }
    size_t zeroBasedIndex = field - 1;
    tests ~= makeFieldVsNumberDelegate(fn, zeroBasedIndex, value);
    maxFieldIndex = (zeroBasedIndex > maxFieldIndex) ? zeroBasedIndex : maxFieldIndex;
}

void fieldVsStringOptionHandler(
    ref FieldsPredicate[] tests, ref size_t maxFieldIndex, FieldVsStringPredicate fn, string option, string optionVal)
{
    auto valSplit = findSplit(optionVal, ":");
    if (valSplit[1].length == 0 || valSplit[2].length == 0)
    {
        throw new Exception(
            format("Invalid option: '--%s %s'. Expected: '--%s <field>:<val>' where <field> is a number and <val> is a string.",
                   option, optionVal, option));
    }
    size_t field;
    string value;
    try
    {
        field = valSplit[0].to!size_t;
        value = valSplit[2].to!string;
    }
    catch (Exception exc)
    {
        throw new Exception(
            format("Invalid values in option: '--%s %s'. Expected: '--%s <field>:<val>' where <field> is a number and <val> a string.",
                   option, optionVal, option));
    }

    if (field == 0)
    {
        throw new Exception(
            format("Invalid option: '--%s %s'. Zero is not a valid field index.", option, optionVal));
    }
    size_t zeroBasedIndex = field - 1;
    tests ~= makeFieldVsStringDelegate(fn, zeroBasedIndex, value);
    maxFieldIndex = (zeroBasedIndex > maxFieldIndex) ? zeroBasedIndex : maxFieldIndex;
}

/* The fieldVsIStringOptionHandler lower-cases the command line argument, assuming the
 * case-insensitive comparison will be done on lower-cased values.
 */
void fieldVsIStringOptionHandler(
    ref FieldsPredicate[] tests, ref size_t maxFieldIndex, FieldVsIStringPredicate fn, string option, string optionVal)
{
    auto valSplit = findSplit(optionVal, ":");
    if (valSplit[1].length == 0 || valSplit[2].length == 0)
    {
        throw new Exception(
            format("Invalid option: '--%s %s'. Expected: '--%s <field>:<val>' where <field> is a number and <val> is a string.",
                   option, optionVal, option));
    }
    size_t field;
    string value;
    try
    {
        field = valSplit[0].to!size_t;
        value = valSplit[2].to!string;
    }
    catch (Exception exc)
    {
        throw new Exception(
            format("Invalid values in option: '--%s %s'. Expected: '--%s <field>:<val>' where <field> is a number and <val> a string.",
                   option, optionVal, option));
    }

    if (field == 0)
    {
        throw new Exception(
            format("Invalid option: '--%s %s'. Zero is not a valid field index.", option, optionVal));
    }
    size_t zeroBasedIndex = field - 1;
    tests ~= makeFieldVsIStringDelegate(fn, zeroBasedIndex, value.to!dstring.toLower);
    maxFieldIndex = (zeroBasedIndex > maxFieldIndex) ? zeroBasedIndex : maxFieldIndex;
}

void fieldVsRegexOptionHandler(
    ref FieldsPredicate[] tests, ref size_t maxFieldIndex, FieldVsRegexPredicate fn, string option, string optionVal,
    bool caseSensitive)
{
    auto valSplit = findSplit(optionVal, ":");
    if (valSplit[1].length == 0 || valSplit[2].length == 0)
    {
        throw new Exception(
            format("Invalid option: '--%s %s'. Expected: '--%s <field>:<val>' where <field> is a number and <val> is a regular expression.",
                   option, optionVal, option));
    }
    size_t field;
    Regex!char value;
    try
    {
        auto modifiers = caseSensitive ? "" : "i";
        field = valSplit[0].to!size_t;
        value = regex(valSplit[2], modifiers);
    }
    catch (Exception exc)
    {
        throw new Exception(
            format("Invalid values in option: '--%s %s'. Expected: '--%s <field>:<val>' where <field> is a number and <val> is a regular expression.",
                   option, optionVal, option));
    }

    if (field == 0)
    {
        throw new Exception(
            format("Invalid option: '--%s %s'. Zero is not a valid field index.", option, optionVal));
    }
    size_t zeroBasedIndex = field - 1;
    tests ~= makeFieldVsRegexDelegate(fn, zeroBasedIndex, value);
    maxFieldIndex = (zeroBasedIndex > maxFieldIndex) ? zeroBasedIndex : maxFieldIndex;
}

void fieldVsFieldOptionHandler(
    ref FieldsPredicate[] tests, ref size_t maxFieldIndex, FieldVsFieldPredicate fn, string option, string optionVal)
{
    auto valSplit = findSplit(optionVal, ":");
    if (valSplit[1].length == 0 || valSplit[2].length == 0)
    {
        throw new Exception(
            format("Invalid option: '--%s %s'. Expected: '--%s <field1>:<field2>' where fields are 1-upped integers.",
                   option, optionVal, option));
    }
    size_t field1;
    size_t field2;
    try
    {
        field1 = valSplit[0].to!size_t;
        field2 = valSplit[2].to!size_t;
    }
    catch (Exception exc)
    {
        throw new Exception(
            format("Invalid values in option: '--%s %s'. Expected: '--%s <field1>:<field2>' where fields are 1-upped integers.",
                   option, optionVal, option));
    }

    if (field1 == 0 || field2 == 0)
    {
        throw new Exception(
            format("Invalid option: '--%s %s'. Zero is not a valid field index.", option, optionVal));
    }

    if (field1 == field2)
    {
        throw new Exception(
            format("Invalid option: '--%s %s'. Field1 and field2 must be different fields", option, optionVal));
    }

    size_t zeroBasedIndex1 = field1 - 1;
    size_t zeroBasedIndex2 = field2 - 1;
    tests ~= makeFieldVsFieldDelegate(fn, zeroBasedIndex1, zeroBasedIndex2);
    maxFieldIndex = max(maxFieldIndex, zeroBasedIndex1, zeroBasedIndex2);
}


void fieldFieldNumOptionHandler(
    ref FieldsPredicate[] tests, ref size_t maxFieldIndex, FieldFieldNumPredicate fn, string option, string optionVal)
{
    size_t field1;
    size_t field2;
    double value;
    auto valSplit = findSplit(optionVal, ":");
    auto invalidOption = (valSplit[1].length == 0 || valSplit[2].length == 0);

    if (!invalidOption)
    {
        auto valSplit2 = findSplit(valSplit[2], ":");
        invalidOption = (valSplit2[1].length == 0 || valSplit2[2].length == 0);

        if (!invalidOption)
        {
            try
            {
                field1 = valSplit[0].to!size_t;
                field2 = valSplit2[0].to!size_t;
                value = valSplit2[2].to!double;
            }
            catch (Exception exc)
            {
                invalidOption = true;
            }
        }
    }

    if (invalidOption)
    {
        throw new Exception(
            format("Invalid values in option: '--%s %s'. Expected: '--%s <field1>:<field2>:<num>' where fields are 1-upped integers.",
                   option, optionVal, option));
    }
    if (field1 == 0 || field2 == 0)
    {
        throw new Exception(
            format("Invalid option: '--%s %s'. Zero is not a valid field index.", option, optionVal));
    }
    if (field1 == field2)
    {
        throw new Exception(
            format("Invalid option: '--%s %s'. Field1 and field2 must be different fields", option, optionVal));
    }

    size_t zeroBasedIndex1 = field1 - 1;
    size_t zeroBasedIndex2 = field2 - 1;
    tests ~= makeFieldFieldNumDelegate(fn, zeroBasedIndex1, zeroBasedIndex2, value);
    maxFieldIndex = max(maxFieldIndex, zeroBasedIndex1, zeroBasedIndex2);
}

/* Command line options - This struct holds the results of command line option processing.
 * It also has a method, processArgs, that invokes command line arg processing.
 */
struct TsvFilterOptions
{
    string programName;
    FieldsPredicate[] tests;         // Derived from tests
    size_t maxFieldIndex;            // Derived from tests
    bool hasHeader = false;          // --H|header
    bool invert = false;             // --invert
    bool disjunct = false;           // --or
    char delim = '\t';               // --delimiter
    bool helpVerbose = false;        // --help-verbose
    bool helpOptions = false;        // --help-options
    bool versionWanted = false;      // --V|version

    /* Returns a tuple. First value is true if command line arguments were successfully
     * processed and execution should continue, or false if an error occurred or the user
     * asked for help. If false, the second value is the appropriate exit code (0 or 1).
     *
     * Returning true (execution continues) means args have been validated and the
     * tests array has been established.
     */
    auto processArgs (ref string[] cmdArgs)
    {
        import std.getopt;
        import std.path : baseName, stripExtension;
        import getopt_inorder;

        programName = (cmdArgs.length > 0) ? cmdArgs[0].stripExtension.baseName : "Unknown_program_name";

        /* Command option handlers - One handler for each option. These conform to the
         * getopt required handler signature, and separate knowledge the specific command
         * option text from the option processing.
         */
        void handlerFldEmpty(string option, string value)    { fieldUnaryOptionHandler(tests, maxFieldIndex, &fldEmpty,    option, value); }
        void handlerFldNotEmpty(string option, string value) { fieldUnaryOptionHandler(tests, maxFieldIndex, &fldNotEmpty, option, value); }
        void handlerFldBlank(string option, string value)    { fieldUnaryOptionHandler(tests, maxFieldIndex, &fldBlank,    option, value); }
        void handlerFldNotBlank(string option, string value) { fieldUnaryOptionHandler(tests, maxFieldIndex, &fldNotBlank, option, value); }

        void handlerFldIsNumeric(string option, string value)  { fieldUnaryOptionHandler(tests, maxFieldIndex, &fldIsNumeric, option, value); }
        void handlerFldIsFinite(string option, string value)   { fieldUnaryOptionHandler(tests, maxFieldIndex, &fldIsFinite, option, value); }
        void handlerFldIsNaN(string option, string value)      { fieldUnaryOptionHandler(tests, maxFieldIndex, &fldIsNaN, option, value); }
        void handlerFldIsInfinity(string option, string value) { fieldUnaryOptionHandler(tests, maxFieldIndex, &fldIsInfinity, option, value); }

        void handlerNumLE(string option, string value) { fieldVsNumberOptionHandler(tests, maxFieldIndex, &numLE, option, value); }
        void handlerNumLT(string option, string value) { fieldVsNumberOptionHandler(tests, maxFieldIndex, &numLT, option, value); }
        void handlerNumGE(string option, string value) { fieldVsNumberOptionHandler(tests, maxFieldIndex, &numGE, option, value); }
        void handlerNumGT(string option, string value) { fieldVsNumberOptionHandler(tests, maxFieldIndex, &numGT, option, value); }
        void handlerNumEQ(string option, string value) { fieldVsNumberOptionHandler(tests, maxFieldIndex, &numEQ, option, value); }
        void handlerNumNE(string option, string value) { fieldVsNumberOptionHandler(tests, maxFieldIndex, &numNE, option, value); }

        void handlerStrLE(string option, string value) { fieldVsStringOptionHandler(tests, maxFieldIndex, &strLE, option, value); }
        void handlerStrLT(string option, string value) { fieldVsStringOptionHandler(tests, maxFieldIndex, &strLT, option, value); }
        void handlerStrGE(string option, string value) { fieldVsStringOptionHandler(tests, maxFieldIndex, &strGE, option, value); }
        void handlerStrGT(string option, string value) { fieldVsStringOptionHandler(tests, maxFieldIndex, &strGT, option, value); }
        void handlerStrEQ(string option, string value) { fieldVsStringOptionHandler(tests, maxFieldIndex, &strEQ, option, value); }
        void handlerStrNE(string option, string value) { fieldVsStringOptionHandler(tests, maxFieldIndex, &strNE, option, value); }

        void handlerStrInFld(string option, string value)    { fieldVsStringOptionHandler(tests, maxFieldIndex, &strInFld,    option, value); }
        void handlerStrNotInFld(string option, string value) { fieldVsStringOptionHandler(tests, maxFieldIndex, &strNotInFld, option, value); }

        void handlerIStrEQ(string option, string value)       { fieldVsIStringOptionHandler(tests, maxFieldIndex, &istrEQ,       option, value); }
        void handlerIStrNE(string option, string value)       { fieldVsIStringOptionHandler(tests, maxFieldIndex, &istrNE,       option, value); }
        void handlerIStrInFld(string option, string value)    { fieldVsIStringOptionHandler(tests, maxFieldIndex, &istrInFld,    option, value); }
        void handlerIStrNotInFld(string option, string value) { fieldVsIStringOptionHandler(tests, maxFieldIndex, &istrNotInFld, option, value); }

        void handlerRegexMatch(string option, string value)     { fieldVsRegexOptionHandler(tests, maxFieldIndex, &regexMatch,    option, value, true); }
        void handlerRegexNotMatch(string option, string value)  { fieldVsRegexOptionHandler(tests, maxFieldIndex, &regexNotMatch, option, value, true); }
        void handlerIRegexMatch(string option, string value)    { fieldVsRegexOptionHandler(tests, maxFieldIndex, &regexMatch,    option, value, false); }
        void handlerIRegexNotMatch(string option, string value) { fieldVsRegexOptionHandler(tests, maxFieldIndex, &regexNotMatch, option, value, false); }

        void handlerFFLE(string option, string value) { fieldVsFieldOptionHandler(tests, maxFieldIndex, &ffLE, option, value); }
        void handlerFFLT(string option, string value) { fieldVsFieldOptionHandler(tests, maxFieldIndex, &ffLT, option, value); }
        void handlerFFGE(string option, string value) { fieldVsFieldOptionHandler(tests, maxFieldIndex, &ffGE, option, value); }
        void handlerFFGT(string option, string value) { fieldVsFieldOptionHandler(tests, maxFieldIndex, &ffGT, option, value); }
        void handlerFFEQ(string option, string value) { fieldVsFieldOptionHandler(tests, maxFieldIndex, &ffEQ, option, value); }
        void handlerFFNE(string option, string value) { fieldVsFieldOptionHandler(tests, maxFieldIndex, &ffNE, option, value); }

        void handlerFFStrEQ(string option, string value)  { fieldVsFieldOptionHandler(tests, maxFieldIndex, &ffStrEQ,  option, value); }
        void handlerFFStrNE(string option, string value)  { fieldVsFieldOptionHandler(tests, maxFieldIndex, &ffStrNE,  option, value); }
        void handlerFFIStrEQ(string option, string value) { fieldVsFieldOptionHandler(tests, maxFieldIndex, &ffIStrEQ, option, value); }
        void handlerFFIStrNE(string option, string value) { fieldVsFieldOptionHandler(tests, maxFieldIndex, &ffIStrNE, option, value); }

        void handlerFFAbsDiffLE(string option, string value) { fieldFieldNumOptionHandler(tests, maxFieldIndex, &ffAbsDiffLE, option, value); }
        void handlerFFAbsDiffGT(string option, string value) { fieldFieldNumOptionHandler(tests, maxFieldIndex, &ffAbsDiffGT, option, value); }
        void handlerFFRelDiffLE(string option, string value) { fieldFieldNumOptionHandler(tests, maxFieldIndex, &ffRelDiffLE, option, value); }
        void handlerFFRelDiffGT(string option, string value) { fieldFieldNumOptionHandler(tests, maxFieldIndex, &ffRelDiffGT, option, value); }

        try
        {
            arraySep = ",";    // Use comma to separate values in command line options
            auto r = getoptInorder(
                cmdArgs,
                "help-verbose",    "     Print full help.", &helpVerbose,
                "help-options",    "     Print the options list by itself.", &helpOptions,
                 std.getopt.config.caseSensitive,
                "V|version",       "     Print version information and exit.", &versionWanted,
                "H|header",        "     Treat the first line of each file as a header.", &hasHeader,
                std.getopt.config.caseInsensitive,
                "or",              "     Evaluate tests as an OR rather than an AND.", &disjunct,
                std.getopt.config.caseSensitive,
                "v|invert",        "     Invert the filter, printing lines that do not match.", &invert,
                std.getopt.config.caseInsensitive,
                "d|delimiter",     "CHR  Field delimiter. Default: TAB. (Single byte UTF-8 characters only.)", &delim,

                "empty",           "FIELD       True if field is empty.", &handlerFldEmpty,
                "not-empty",       "FIELD       True if field is not empty.", &handlerFldNotEmpty,
                "blank",           "FIELD       True if field is empty or all whitespace.", &handlerFldBlank,
                "not-blank",       "FIELD       True if field contains a non-whitespace character.", &handlerFldNotBlank,

                "is-numeric",      "FIELD       True if field is interpretable as a number.", &handlerFldIsNumeric,
                "is-finite",       "FIELD       True if field is interpretable as a number and is not NaN or infinity.", &handlerFldIsFinite,
                "is-nan",          "FIELD       True if field is NaN.", &handlerFldIsNaN,
                "is-infinity",     "FIELD       True if field is infinity.", &handlerFldIsInfinity,

                "le",              "FIELD:NUM   FIELD <= NUM (numeric).", &handlerNumLE,
                "lt",              "FIELD:NUM   FIELD <  NUM (numeric).", &handlerNumLT,
                "ge",              "FIELD:NUM   FIELD >= NUM (numeric).", &handlerNumGE,
                "gt",              "FIELD:NUM   FIELD >  NUM (numeric).", &handlerNumGT,
                "eq",              "FIELD:NUM   FIELD == NUM (numeric).", &handlerNumEQ,
                "ne",              "FIELD:NUM   FIELD != NUM (numeric).", &handlerNumNE,

                "str-le",          "FIELD:STR   FIELD <= STR (string).", &handlerStrLE,
                "str-lt",          "FIELD:STR   FIELD <  STR (string).", &handlerStrLT,
                "str-ge",          "FIELD:STR   FIELD >= STR (string).", &handlerStrGE,
                "str-gt",          "FIELD:STR   FIELD >  STR (string).", &handlerStrGT,
                "str-eq",          "FIELD:STR   FIELD == STR (string).", &handlerStrEQ,
                "istr-eq",         "FIELD:STR   FIELD == STR (string, case-insensitive).", &handlerIStrEQ,
                "str-ne",          "FIELD:STR   FIELD != STR (string).", &handlerStrNE,
                "istr-ne",         "FIELD:STR   FIELD != STR (string, case-insensitive).", &handlerIStrNE,
                "str-in-fld",      "FIELD:STR   FIELD contains STR (substring search).", &handlerStrInFld,
                "istr-in-fld",     "FIELD:STR   FIELD contains STR (substring search, case-insensitive).", &handlerIStrInFld,
                "str-not-in-fld",  "FIELD:STR   FIELD does not contain STR (substring search).", &handlerStrNotInFld,
                "istr-not-in-fld", "FIELD:STR   FIELD does not contain STR (substring search, case-insensitive).", &handlerIStrNotInFld,

                "regex",           "FIELD:REGEX   FIELD matches regular expression.", &handlerRegexMatch,
                "iregex",          "FIELD:REGEX   FIELD matches regular expression, case-insensitive.", &handlerIRegexMatch,
                "not-regex",       "FIELD:REGEX   FIELD does not match regular expression.", &handlerRegexNotMatch,
                "not-iregex",      "FIELD:REGEX   FIELD does not match regular expression, case-insensitive.", &handlerIRegexNotMatch,

                "ff-le",           "FIELD1:FIELD2   FIELD1 <= FIELD2 (numeric).", &handlerFFLE,
                "ff-lt",           "FIELD1:FIELD2   FIELD1 <  FIELD2 (numeric).", &handlerFFLT,
                "ff-ge",           "FIELD1:FIELD2   FIELD1 >= FIELD2 (numeric).", &handlerFFGE,
                "ff-gt",           "FIELD1:FIELD2   FIELD1 >  FIELD2 (numeric).", &handlerFFGT,
                "ff-eq",           "FIELD1:FIELD2   FIELD1 == FIELD2 (numeric).", &handlerFFEQ,
                "ff-ne",           "FIELD1:FIELD2   FIELD1 != FIELD2 (numeric).", &handlerFFNE,
                "ff-str-eq",       "FIELD1:FIELD2   FIELD1 == FIELD2 (string).", &handlerFFStrEQ,
                "ff-istr-eq",      "FIELD1:FIELD2   FIELD1 == FIELD2 (string, case-insensitive).", &handlerFFIStrEQ,
                "ff-str-ne",       "FIELD1:FIELD2   FIELD1 != FIELD2 (string).", &handlerFFStrNE,
                "ff-istr-ne",      "FIELD1:FIELD2   FIELD1 != FIELD2 (string, case-insensitive).", &handlerFFIStrNE,

                "ff-absdiff-le",   "FIELD1:FIELD2:NUM   abs(FIELD1 - FIELD2) <= NUM", &handlerFFAbsDiffLE,
                "ff-absdiff-gt",   "FIELD1:FIELD2:NUM   abs(FIELD1 - FIELD2)  > NUM", &handlerFFAbsDiffGT,
                "ff-reldiff-le",   "FIELD1:FIELD2:NUM   abs(FIELD1 - FIELD2) / min(abs(FIELD1), abs(FIELD2)) <= NUM", &handlerFFRelDiffLE,
                "ff-reldiff-gt",   "FIELD1:FIELD2:NUM   abs(FIELD1 - FIELD2) / min(abs(FIELD1), abs(FIELD2))  > NUM", &handlerFFRelDiffGT,
                );

            /* Both help texts are a bit long. In this case, for "regular" help, don't
             * print options, just the text. The text summarizes the options.
             */
            if (r.helpWanted)
            {
                stdout.write(helpText);
                return tuple(false, 0);
            }
            else if (helpVerbose)
            {
                defaultGetoptPrinter(helpTextVerbose, r.options);
                return tuple(false, 0);
            }
            else if (helpOptions)
            {
                defaultGetoptPrinter(helpTextOptions, r.options);
                return tuple(false, 0);
            }
            else if (versionWanted)
            {
                import tsvutils_version;
                writeln(tsvutilsVersionNotice("tsv-filter"));
                return tuple(false, 0);
            }
        }
        catch (Exception exc)
        {
            stderr.writefln("[%s] Error processing command line arguments: %s", programName, exc.msg);
            return tuple(false, 1);
        }
        return tuple(true, 0);
    }
}

/** tsvFilter processes the input files and runs the tests.
 */
void tsvFilter(in TsvFilterOptions cmdopt, in string[] inputFiles)
{
    import std.algorithm : all, any, splitter;
    import std.range;
    import tsvutil : BufferedOutputRange, throwIfWindowsNewlineOnUnix;

    /* BufferedOutputRange improves performance on narrow files with high percentages of
     * writes. Want responsive output if output is rare, so ensure the first matched
     * line is written, and that writes separated by long stretches of non-matched lines
     * are written.
     */
    enum maxInputLinesWithoutBufferFlush = 1024;
    size_t inputLinesWithoutBufferFlush = maxInputLinesWithoutBufferFlush + 1;

    auto bufferedOutput = BufferedOutputRange!(typeof(stdout))(stdout);

    /* Process each input file, one line at a time. */
    auto lineFields = new char[][](cmdopt.maxFieldIndex + 1);
    bool headerWritten = false;
    foreach (filename; (inputFiles.length > 0) ? inputFiles : ["-"])
    {
        auto inputStream = (filename == "-") ? stdin : filename.File();
        foreach (lineNum, line; inputStream.byLine.enumerate(1))
        {
            if (lineNum == 1) throwIfWindowsNewlineOnUnix(line, filename, lineNum);
            if (lineNum == 1 && cmdopt.hasHeader)
            {
                /* Header. Output on the first file, skip subsequent files. */
                if (!headerWritten)
                {
                    bufferedOutput.appendln(line);
                    headerWritten = true;
                }
            }
            else
            {
                /* Copy the needed number of fields to the fields array. */
                int fieldIndex = -1;
                foreach (fieldValue; line.splitter(cmdopt.delim))
                {
                    if (fieldIndex == cast(long) cmdopt.maxFieldIndex) break;
                    fieldIndex++;
                    lineFields[fieldIndex] = fieldValue;
                }

                if (fieldIndex == -1)
                {
                    assert(line.length == 0);
                    /* Bug work-around. Currently empty lines are not handled properly by splitter.
                     *   Bug: https://issues.dlang.org/show_bug.cgi?id=15735
                     *   Pull Request: https://github.com/D-Programming-Language/phobos/pull/4030
                     * Work-around: Point to the line. It's an empty string.
                     */
                    fieldIndex++;
                    lineFields[fieldIndex] = line;
                }

                if (fieldIndex < cast(long) cmdopt.maxFieldIndex)
                {
                    throw new Exception(
                        format("Not enough fields in line. File: %s, Line: %s",
                               (filename == "-") ? "Standard Input" : filename, lineNum));
                }

                /* Run the tests. Tests will fail (throw) if a field cannot be converted
                 * to the expected type.
                 */
                try
                {
                    inputLinesWithoutBufferFlush++;
                    bool passed = cmdopt.disjunct ?
                        cmdopt.tests.any!(x => x(lineFields)) :
                        cmdopt.tests.all!(x => x(lineFields));
                    if (cmdopt.invert) passed = !passed;
                    if (passed)
                    {
                        bool wasFlushed = bufferedOutput.appendln(line);
                        if (wasFlushed) inputLinesWithoutBufferFlush = 0;
                        else if (inputLinesWithoutBufferFlush > maxInputLinesWithoutBufferFlush)
                        {
                            bufferedOutput.flush;
                            inputLinesWithoutBufferFlush = 0;
                        }
                    }
                }
                catch (Exception exc)
                {
                    throw new Exception(
                        format("Could not process line or field: %s\n  File: %s Line: %s%s",
                               exc.msg, (filename == "-") ? "Standard Input" : filename, lineNum,
                               (lineNum == 1) ? "\n  Is this a header line? Use --header to skip." : ""));
                }
            }
        }
    }
}
