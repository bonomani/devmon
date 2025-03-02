#!/usr/bin/perl
use strict;
use warnings;
use List::Util 'max';
use Test::More tests => 255;
use Scalar::Util 'looks_like_number';
use bignum;
use constant EPSILON => 1e-9;

# Global debugging and tracing settings
my %g = (
    debug => 1,  # Set to 1 for less verbose debugging
    trace => 1,  # Set to 1 for more verbose tracing
);

my %vars;

# Define patterns for token recognition
my %patterns = (
    R => qr/(?<R>-?\d+(?:\.\d+)?)/,                        # Real numbers
    R_p => qr/(?<R_p>\d+(?:\.\d+)?)/,                      # Positive real numbers
    R_pnz => qr/(?<R_pnz>(?:0*[1-9]\d*)(?:\.\d+)?)/,       # Positive non-zero real numbers
    R_n => qr/(?<R_n>-\d+(?:\.\d+)?)/,                     # Negative real numbers
    R_nnz => qr/(?<R_nnz>(?:-0*[1-9]\d*)(?:\.\d+)?)/,      # Negative non-zero real numbers
    R_nz => qr/(?<R_nz>-?\d+(?:\.\d+)?)/,                  # Non-zero real numbers
    Z => qr/(?<Z>-?\d+)/,                                  # Integers
    Z_p => qr/(?<Z_p>0|[1-9]\d*)/,                         # Positive integers
    Z_pnz => qr/(?<Z_pnz>[1-9]\d*)/,                       # Positive non-zero integers
    Z_n => qr/(?<Z_n>-\d+)/,                               # Negative integers
    Z_nnz => qr/(?<Z_nnz>-\d+)/,                           # Negative non-zero integers
    Z_nz => qr/(?<Z_nz>-?[1-9]\d*)/,                       # Non-zero integers
    num => qr/(?<num>\d+(?:\.\d*)?)/,                      # Floating-point numbers
    int => qr/(?<int>[1-9]\d*|0)/,                         # Integers
    op => qr/(?<op><=|>=|!=|=|<|>|\^|%|\+|\-|\*|\/|\||&|or|and|\|\|)/,  # Operators
    double_quote_str => qr/(?<double_quote_str>"(?:\\.|[^"\\])*")/,         # Double-quoted strings with escape handling
    single_quote_str => qr/(?<single_quote_str>'(?:\\.|[^'\\])*')/,         # Single-quoted strings with escape handling
    quote_str => qr/(?<quote_str>(["'])(.*?(?:\\.|(?:(?!\1).)*))\1)/,       # General quoted strings with escape handling
    str => qr/(?<str>.+)/,                                    # Any string
    var => qr/(?<var>\{\w+\})/,                               # Placeholder variables like {x}, {y}, {name}
    #funci1 => qr/(?<func>\w+)\s*\(\s*(?<func_args>.*?)\s*\)/,    # Function calls with arguments
    func => qr/(?<func>\w+)\s*\(\s*(?<func_args>(?:[^()]*|\((?-1)\))*)\)/,  # Nested function calls
    parens => qr/(?<parens>[()])/,                              # Parentheses
    comma => qr/(?<comma>,)/,                                   # Comma
    start_ws => qr/(?<start_ws>)^\s+/,                          # Starting whitespace (to ignore)
    invalid => qr/(?<invalid>)\S+/,                             # Invalid tokens
);

# Function definitions
my %functions = (
    'round' => {
        func => sub {
            my ($number, $decimals) = @_;
            $decimals //= 0;  # Default to 0 if $decimals is undefined
            return sprintf("%.${decimals}f", "".($number + 0)); # force num context then string context (for object)
        },
        args => ['R', 'Z_p?'],
    },
    'max' => {
        func => \&max,
        args => ['num'],
        var_args => 1,  # Accepts a variable number of numeric arguments
    },
    'concat' => {
        func => sub {
            return join("", @_);
        },
        args => ['str'],
        var_args => 1,  # Accepts a variable number of string arguments
    },
    'substr' => {
        func => sub {
            my ($string, $start, $length) = @_;
            return substr($string, $start, $length);
        },
        args => ['str', 'int', 'int'],
    },
    'length' => {
        func => sub {
            my ($string) = @_;
            return length($string);
        },
        args => ['str'],
    },
    'uc' => {
        func => sub {
            my ($string) = @_;
            return uc($string);
        },
        args => ['str'],
    },
);

# Generate a regex pattern for function names dynamically
my $function_names = join('|', keys %functions);
my $functions_regex = qr/\b(?:$function_names)\b/;

# Common subroutine for tokenizing expressions
sub tokenize_function {
    my ($expr, $is_func_args, $func_arg_counts_ref) = @_;
    my @tokens;
    my $count = 0;

    while ($expr =~ /\G(
        $patterns{start_ws}             # Starting whitespace (to ignore)
        |$patterns{op}                  # Operators
        |$patterns{func}                # Function calls with arguments
        |$patterns{num}                 # Numbers
        |$patterns{double_quote_str}    # Double-quoted strings
        |$patterns{single_quote_str}    # Single-quoted strings
        |$patterns{var}                 # Variables like {x}, {y}, {name}
        |$patterns{parens}              # Parentheses
        |$patterns{comma}               # Comma
        |$patterns{invalid}             # Invalid
        |\s+                            # Whitespace (to ignore)
    )/gcx) {
        my $token = $&;  # $& holds the entire match

        # Check which pattern matched using named captures
        if (defined $+{start_ws}) {
            next;
        } elsif (defined $+{op} or defined $+{parens}) {
            # Handle operators and parentheses
            push @tokens, $token;
        } elsif (defined $+{func}) {
            # Handle function calls with arguments
            my $func_name = $+{func};
            my $arg_counts_ref;
            my ($args_tokens_ref, $func_arg_counts_ref) = tokenize_function($+{func_args}, 1, $func_arg_counts_ref);
            push @tokens, $func_name, "(", @$args_tokens_ref, ")";
        } elsif (defined $+{num}) {
            # Handle numbers
            push @tokens, $token;
        } elsif (defined $+{double_quote_str}) {
            # Handle double-quoted strings
            push @tokens, $token;
        } elsif (defined $+{single_quote_str}) {
            # Handle single-quoted strings
            push @tokens, $token;
        } elsif (defined $+{var}) {
            # Handle variables like {x}, {y}, {name}
            push @tokens, $token;
        } elsif (defined $+{comma}) {
            push @tokens, $token;
            $count++;
        } elsif (defined $+{invalid}) {
            # Handle any other character (invalid token)
            die "Invalid token encountered: $token";
        }
    }

    if ($is_func_args) {
        $count++ if @tokens;
        push @$func_arg_counts_ref, $count;
    }
    return (\@tokens, $func_arg_counts_ref);
}

# Tokenize and parse expression
sub tokenize {
    my ($expr) = @_;
    my $func_arg_counts_ref = [];  # Initialize as an empty array reference
    (my $tokens, $func_arg_counts_ref) = tokenize_function($expr, 0, $func_arg_counts_ref);
    return ($tokens, $func_arg_counts_ref);
}



# Operator precedence
sub precedence {
    my ($op) = @_;
    return 5 if $op eq '^';                                  # Exponentiation
    return 4 if $op eq 'neg';                                # Unary negation
    return 3 if $op eq '*' || $op eq '/' || $op eq '%';      # Multiplication, division, modulus
    return 2 if $op eq '+' || $op eq '-';                    # Addition, subtraction
    return 1 if $op eq '<=' || $op eq '>=' || $op eq '<' || $op eq '>' || $op eq '=' || $op eq '!=';  # Comparison
    return 0 if $op eq 'or' || $op eq 'and' || $op eq '||';  # Logical operators
    return -1;                                               # Lowest precedence for others
}

# Operator associativity
sub is_right_associative {
    my ($op) = @_;
    return 1 if $op eq '^';  # Exponentiation is right-associative
    return 0;
}

# Handle operators within infix_to_postfix
sub handle_operator {
    my ($token, $ops, $output) = @_;
    while (@$ops && $ops->[-1] ne '(' &&
          (precedence($ops->[-1]) > precedence($token) ||
           (precedence($ops->[-1]) == precedence($token) && !is_right_associative($token)))) {
        print "Popping operator from stack to output: ", $ops->[-1], "\n" if $g{trace};
        push @$output, pop @$ops;
    }
    push @$ops, $token;
}

# Convert infix expression to postfix notation
sub infix_to_postfix {
    my ($tokens, $func_arg_counts) = @_;

    my @output;
    my @stack;
    my $arg_counts_index = 0;  # Index for iterating through @func_arg_counts
    my $expecting_unary = 1; # Flag to indicate if the next operator is unary

    foreach my $token (@$tokens) {
        if ($token =~ $patterns{num} || $token =~ $patterns{var}) {
            push @output, $token;  # Output numbers directly
            print "Pushing to Output: $token\n";
            $expecting_unary = 0;
        } elsif ($token eq '(') {
            push @stack, $token;
            print "Pushing to Stack: (\n";
            $expecting_unary = 1;
        } elsif ($token eq ')') {
            while (@stack && $stack[-1] ne '(') {
                push @output, pop @stack;
                print "Popping from Stack to Output: " . $output[-1] . "\n";
            }
            pop @stack;  # Pop the '('
            print "Popping from Stack: (\n";

            # Check if the token before '(' is a function name
            if (@stack && $stack[-1] =~ /^\w+$/ && $stack[-1] ne 'neg') {
                my $func_token = pop @stack;  # Pop function name
                if ($arg_counts_index < @$func_arg_counts) {
                    my $arg_counts = $func_arg_counts->[$arg_counts_index++];  # Get argument count
                    push @output, $arg_counts;
                    push @output, $func_token;  # Push function name after its arguments
                    print "Pushing Number of Args for $func_token: $arg_counts\n";
                } else {
                    die "No argument count found for function: $func_token";
                }
            }
            $expecting_unary = 0;
        } elsif ($token =~ $patterns{op}) {
            if ($token eq '-' && $expecting_unary) {
                push @stack, 'neg';
                print "Pushed unary operator to stack, current stack: @stack\n" if $g{trace};
            } else {
                handle_operator($token, \@stack, \@output);
            }
            $expecting_unary = 1;
        } elsif ($token =~ /^\w+$/) {
            # Handle function names and their arguments
            push @stack, $token;
            print "Pushing to Stack: $token\n";
            $expecting_unary = 1;
        } elsif ($token eq ',') {
            # Handle comma: pop operators until '(' is encountered
            while (@stack && $stack[-1] ne '(') {
                push @output, pop @stack;
                print "Popping from Stack to Output: " . $output[-1] . "\n";
            }
            $expecting_unary = 1;
        } elsif ($token =~ $patterns{single_quote_str}) {
            push @stack, $token;
            print "Pushing to Stack: $token\n";
            $expecting_unary = 0;
        } elsif ($token =~ $patterns{double_quote_str}) {
            push @stack, $token;
            print "Pushing to Stack: $token\n";
            $expecting_unary = 0;
        } else {
            die "Invalid token encountered: $token";
        }
    }

    while (@stack) {
        push @output, pop @stack;
        print "Popping from Stack to Output: " . $output[-1] . "\n";
    }

    return \@output;
}

# Validate and execute function calls dynamically
sub validate_args_and_call_function {
    my ($func_name, @args) = @_;
    my $function = $functions{$func_name};
    my $arg_types = $function->{args};

    # Handle variable argument functions
    if ($function->{var_args}) {
        foreach my $arg (@args) {
            if ($arg !~ $patterns{$arg_types->[0]}) {
                die "Invalid type for argument in $func_name: expected $arg_types->[0]";
            }
        }
    } else {
        my $expected_args = scalar @$arg_types;
        my $provided_args = scalar @args;
        my $min_args = grep { $_ !~ /\?$/ } @$arg_types;  # Count required arguments

        if ($provided_args < $min_args || $provided_args > $expected_args) {
            die "Invalid number of arguments for $func_name: expected between $min_args and $expected_args, got $provided_args";
        }

        for (my $i = 0; $i < @$arg_types; $i++) {
            next if $i >= $provided_args && $arg_types->[$i] =~ /\?$/;  # Skip optional parameters if not provided

            # Remove '?' for pattern matching
            (my $type = $arg_types->[$i]) =~ s/\?$//;

            if ($args[$i] !~ /^$patterns{$type}$/) {
                die "Invalid type for argument $i : $args[$i] in $func_name: expected $type";
            }
        }
    }
    return $function->{func}->(@args);
}

# Evaluate operators
sub evaluate_operator {
    my ($op, $a, $b) = @_;
    return $a + $b if $op eq '+';
    return $a - $b if $op eq '-';
    return $a * $b if $op eq '*';
    return $a / $b if $op eq '/';
    return $a % $b if $op eq '%';
    return $a ** $b if $op eq '^';
    return $a | $b if $op eq '|';
    return $a & $b if $op eq '&';
    return ($a < $b || abs($a - $b) <= EPSILON) ? 1 : 0 if $op eq '<=';
    return ($a > $b || abs($a - $b) <= EPSILON) ? 1 : 0 if $op eq '>=';
    return abs($a - $b) <= EPSILON ? 0 : 1 if $op eq '!=';
    return abs($a - $b) <= EPSILON ? 1 : 0 if $op eq '=';
    return ($a < $b && abs($a - $b) > EPSILON) ? 1 : 0 if $op eq '<';
    return ($a > $b && abs($a - $b) > EPSILON) ? 1 : 0 if $op eq '>';
    return $a || $b ? 1 : 0 if $op eq 'or' || $op eq '||';
    return $a && $b ? 1 : 0 if $op eq 'and';
    die "Unknown operator: $op";
}

# Function to evaluate postfix expression
sub evaluate_postfix {
    my ($tokens) = @_;

    my @stack;

    foreach my $token (@$tokens) {
        if ($token =~ $patterns{var}) {
            $token = $vars{$1} // die "Variable $1 not defined" if $token =~ /\{(\w+)\}/;
            push @stack, $token;  # Push variable value onto the stack
        } elsif ($token =~ $patterns{num}) {
            push @stack, $token;  # Push numbers onto the stack
            print "Pushing to Stack: $token\n";
        } elsif ($token =~ $patterns{single_quote_str}) {
            $token =~ s/\\'/\'/g;
            $token =~ s/\\\\/\\/g;
            push @stack, substr($token, 1, -1);  # Push string onto the stack
            print "Pushing to Stack: $token\n";
        } elsif ($token =~ $patterns{double_quote_str}) {
            $token =~ s/\\"/\"/g;
            $token =~ s/\\\\/\\/g;
            push @stack, substr($token, 1, -1);  # Push string onto the stack
            print "Pushing to Stack: $token\n";
        } elsif ($token =~ /$patterns{op}/) {
            my $b = pop @stack // 0;
            my $a = pop @stack // 0;
            print "Applying operator $token to operands: $a, $b\n" if $g{trace};
            my $result = evaluate_operator($token, $a, $b);
            push @stack, $result;
            print "Pushing Result to Stack: $result\n";
        } elsif ($token eq 'neg') {
            my $a = pop @stack;
            push @stack, -$a;
        } elsif ($token =~ $functions_regex) {
            # Handle function names
            my $func_name = $token;
            my @args = splice(@stack, - (pop @stack));
            my $result = validate_args_and_call_function($func_name, @args);
            print "Function $func_name result: $result\n" if $g{trace};
            push @stack, $result;
        } else {
            die "Unexpected token encountered during evaluation: $token";
        }
    }

    if (@stack == 1) {
        print "\nFinal Result: $stack[0]\n";
        return $stack[0];
    } else {
        die "Error: Invalid expression or stack state after evaluation.";
    }
}

# Calculate the expression by first converting to postfix then evaluating it
sub calculate {
    my ($expr) = @_;
    print "Input Infix Expression: $expr\n\n";

    my ($tokens, $func_arg_counts) = tokenize($expr);
    print "Tokens:\n" . join("|", @$tokens) . "\n\n";

    my $postfix_tokens = infix_to_postfix($tokens, $func_arg_counts);
    print "Postfix Expression:\n" . join("|", @$postfix_tokens) . "\n\n";

    return evaluate_postfix($postfix_tokens);
}

# Define and run tests
sub run_tests {
    # Test cases
    my @tests = (
        # Arithmetic and basic operations
        ['3 + 5 * 2', '13', 'Test basic arithmetic precedence'],
        ['2^3', '8', 'Test exponentiation operator'],
        ['5 % 2', '1', 'Test modulus operator'],
        ['4 | 1', '5', 'Test bitwise OR operator'],
        ['4 & 1', '0', 'Test bitwise AND operator'],
        ['2 + 2', '4', 'Test addition'],
        ['2 - 2', '0', 'Test subtraction'],
        ['2 * 3', '6', 'Test multiplication'],
        ['6 / 3', '2', 'Test division'],
        ['3 + 5 % 2', '4', 'Test mixed modulus and addition'],
        ['2^3 + 1', '9', 'Test mixed exponentiation and addition'],
        ['(2^3) + 1', '9', 'Test parenthesis with exponentiation'],
        ['(2^3) + (4^2)', '24', 'Test complex exponentiation'],
        ['2 * 3 + 4 * 5', '26', 'Test mixed multiplication and addition'],
        ['2 * (3 + 4) * 5', '70', 'Test complex multiplication with parenthesis'],
        ['5 + 2 * 3', '11', 'Test addition and multiplication'],
        ['(5 + 2) * 3', '21', 'Test parenthesis changing precedence'],
        ['2^3 * 2', '16', 'Test exponentiation with multiplication'],
        ['2 * 3^2', '18', 'Test multiplication with exponentiation'],
        ['2 + 3^2', '11', 'Test addition with exponentiation'],
        ['3 * (2 + 4) - 2', '16', 'Test complex expression with parenthesis and subtraction'],
        ['2 + 3 * 4 - 5', '9', 'Test mixed addition, multiplication, and subtraction'],
        ['2 + 2 * 3', '8', 'Test addition and multiplication'],
        ['2 * 3 + 4', '10', 'Test multiplication and addition'],
        ['(2 + 3) * 4', '20', 'Test parenthesis with addition and multiplication'],
        ['2^2 + 2', '6', 'Test exponentiation with addition'],
        ['4 / 2 + 1', '3', 'Test division and addition'],
        ['4 / (2 + 2)', '1', 'Test division with parenthesis'],
        ['3 + 3 * 3', '12', 'Test mixed addition and multiplication'],
        ['3 * 3 + 3', '12', 'Test mixed multiplication and addition'],
        ['3 - 3 + 3', '3', 'Test mixed subtraction and addition'],
        ['6 / 2 - 1', '2', 'Test division and subtraction'],
        ['6 - 2 / 2', '5', 'Test subtraction and division'],
        ['4 * 2 / 2', '4', 'Test multiplication and division'],
        ['4 / 2 * 2', '4', 'Test division and multiplication'],
        ['(3 + 3) * (2 + 2)', '24', 'Test nested parenthesis with addition and multiplication'],
        ['(3 * 3) + (2 * 2)', '13', 'Test nested parenthesis with multiplication and addition'],
        ['(2 + 3) - (1 + 1)', '3', 'Test nested parenthesis with addition and subtraction'],
        ['(4 - 2) * 2', '4', 'Test nested parenthesis with subtraction and multiplication'],
        ['(4 - 2) / 2', '1', 'Test nested parenthesis with subtraction and division'],
        ['3 * (2 + 1)', '9', 'Test multiplication with parenthesis addition'],
        ['3 + (2 * 2)', '7', 'Test addition with parenthesis multiplication'],
        ['3 - (2 + 1)', '0', 'Test subtraction with parenthesis addition'],
        ['3 * (2 - 1)', '3', 'Test multiplication with parenthesis subtraction'],
        ['3 / (2 - 1)', '3', 'Test division with parenthesis subtraction'],
        ['(2 + 3) * (4 + 1)', '25', 'Test multiplication with nested parenthesis'],
        ['4 + 3 * 2', '10', 'Test addition with multiplication'],
        ['(4 + 3) * 2', '14', 'Test addition with parenthesis and multiplication'],
        ['5 + 2 * 4', '13', 'Test addition and multiplication'],
        ['5 * 2 + 4', '14', 'Test multiplication and addition'],
        ['(5 * 2) + 4', '14', 'Test multiplication and addition with parenthesis'],
        ['5 * (2 + 4)', '30', 'Test multiplication with parenthesis addition'],
        ['10 / 2 * 3', '15', 'Test division and multiplication'],
        ['10 / (2 * 3)', '1.66666666666667', 'Test division with parenthesis multiplication'],

        # Rounding and max functions
        ['round(3.14159, 2)', '3.14', 'Test rounding to 2 decimal places'],
        ['round(3.5, 0)', '4', 'Test rounding to 0 decimal places'],
        ['round(3.14159, 4)', '3.1416', 'Test rounding to 4 decimal places'],
        ['round(2.5678, 3)', '2.568', 'Test round with different decimals'],
        ['round(3.1459, 2)', '3.15', 'Test rounding up'],
        ['round(2.5001, 2)', '2.50', 'Test rounding edge case'],
        ['round(2.4999, 2)', '2.50', 'Test rounding down'],
        ['round(5.5678, 3)', '5.568', 'Test rounding with more decimal places'],
        ['round(max(2.5, 3.7, 4.1), 1)', '4.1', 'Test nested max and round with different values'],
        ['round(max(1.2, 2.3, 3.4), 1)', '3.4', 'Test round max with decimal places again'],
        ['round(max(4.4, 4.5, 4.6), 1)', '4.6', 'Test round max with decimal places'],
        ['round(10.678, 2)', '10.68', 'Test rounding large number'],
        ['round(2.4567, 3)', '2.457', 'Test rounding with three decimals'],
        ['round(1.9999, 3)', '2.000', 'Test rounding edge case with trailing zeros'],
        ['round(3.3333, 2)', '3.33', 'Test rounding down to 2 decimal places'],
        ['round(4.678, 2)', '4.68', 'Test rounding up with two decimal places'],
        ['round(2.5555, 2)', '2.56', 'Test rounding up with more decimal places'],
        ['round(4.9999, 2)', '5.00', 'Test rounding edge case near integer'],
        ['round(4.4444, 3)', '4.444', 'Test rounding to 3 decimal places'],
        ['round(1.23456, 4)', '1.2346', 'Test rounding to four decimal places'],
        ['round(4.5678 + 2.4321, 2)', '7.00', 'Test rounding with addition again'],
        ['round(max(1.1234, 2.2345), 3)', '2.235', 'Test round and max with high precision'],
        ['round(2.5678 + 3.4321, 3)', '6.000', 'Test round with addition'],
        ['max(1, 2, 3, 4.5)', '4.5', 'Test max function'],
        ['max(10, 20, 5)', '20', 'Test max function with integers'],
        ['max(1.1, 2.2, 3.3)', '3.3', 'Test max function with floats'],
        ['max(4.4, 4.5, 4.6)', '4.6', 'Test max with close values'],
        ['max(2, 3, 1)', '3', 'Test max with integers again'],
        ['max(1, 2, 3, 4.5, 5.5)', '5.5', 'Test max with more values'],
        ['max(10, 20, 5, 15)', '20', 'Test max with integers again'],
        ['max(2, 4, 6, 8)', '8', 'Test max with even numbers'],
        ['max(round(1.1, 1), round(2.2, 1))', '2.2', 'Test max with rounded values'],
        ['max(2.2, 2.3, 2.4, 2.5)', '2.5', 'Test max with multiple close float values'],
        ['round(max(4.444, 4.555, 4.666), 2)', '4.67', 'Test rounding with max'],
        ['max(2, 3, 4, 5, 6)', '6', 'Test max with several integers'],
        ['round(max(1.111, 2.222, 3.333), 1)', '3.3', 'Test rounding with max and one decimal place'],
        ['round(max(1.234, 2.345, 3.456), 2)', '3.46', 'Test rounding with max and multiple decimals'],
        ['max(3, 3.5, 4, 4.5)', '4.5', 'Test max with mixed integers and floats'],
        ['max(2.5, 3.5) + 1.5', '5', 'Test max addition'],
        ['max(2, 3, 5) - 1', '4', 'Test max with subtraction'],
        ['max(4, 5, 6, 7, 8)', '8', 'Test max with multiple integers'],
        ['max(2.5, 2.6, 2.7, 2.8)', '2.8', 'Test max with several close float values'],

        # Logical comparisons
        ['5 >= 3', '1', 'Test greater than or equal to operator'],
        ['5 <= 3', '0', 'Test less than or equal to operator'],
        ['5 != 3', '1', 'Test not equal to operator'],
        ['5 = 5', '1', 'Test equal to operator'],
        ['3 < 5', '1', 'Test less than operator'],
        ['3 > 5', '0', 'Test greater than operator'],
        ['1 or 0', '1', 'Test logical OR operator'],
        ['1 and 0', '0', 'Test logical AND operator'],
        ['1 || 0', '1', 'Test logical OR operator (||)'],
        ['2 < 3 and 3 < 4', '1', 'Test combined logical and comparison'],
        ['2 > 3 or 3 < 4', '1', 'Test combined logical OR and comparison'],
        ['1 and 1', '1', 'Test logical AND with true values'],
        ['1 and 0', '0', 'Test logical AND with one false value'],
        ['0 and 0', '0', 'Test logical AND with false values'],
        ['1 or 1', '1', 'Test logical OR with true values'],
        ['1 or 0', '1', 'Test logical OR with one true value'],
        ['0 or 0', '0', 'Test logical OR with false values'],
        ['1 || 1', '1', 'Test logical OR with true values using ||'],
        ['1 || 0', '1', 'Test logical OR with one true value using ||'],
        ['0 || 0', '0', 'Test logical OR with false values using ||'],

        # Floating-point comparisons with epsilon
        ['3.0 > 2.999999999', '1', 'Test greater than with floating-point numbers'],
        ['2.999999999 > 3.0', '0', 'Test greater than with floating-point numbers - false case'],
        ['3.0 >= 2.999999999', '1', 'Test greater than or equal with floating-point numbers'],
        ['2.999999999 >= 3.0', '0', 'Test greater than or equal with floating-point numbers - false case'],
        ['3.0 < 3.000000001', '1', 'Test less than with floating-point numbers'],
        ['3.000000001 < 3.0', '0', 'Test less than with floating-point numbers - false case'],
        ['3.0 <= 3.000000001', '1', 'Test less than or equal with floating-point numbers'],
        ['3.000000001 <= 3.0', '0', 'Test less than or equal with floating-point numbers - false case'],
        ['3.0000000000 = 3.0000000001', '1', 'Test equality with floating-point numbers within epsilon'],
        ['3.0000000000 != 3.0000000001', '0', 'Test inequality with floating-point numbers within epsilon'],
        ['3.0 = 3.0000001', '0', 'Test equality with floating-point numbers outside epsilon - false case'],
        ['3.0 != 3.0000001', '1', 'Test inequality with floating-point numbers outside epsilon'],

        # Complex expressions
        ['(2 + 3 * (4 - 1) / 2) ^ 2 + max(1, 5, round(4.567, 1))', '47.25', 'Test nested arithmetic with max and round'],
        ['round((3.14159 + 2) * 2, 2) - (max(1, 2, 3) + 2)', '5.28', 'Test round and max with nested arithmetic'],
        ['(2^3 + 4) * (round(5.678, 1) - 1)', '56.4', 'Test exponentiation with round and nested arithmetic'],
        ['(4 + 3 * 2) / max(1, 2, 3) + round(2.555, 1)', '5.93333333333333', 'Test nested arithmetic with max and round'],
        ['round((2.5 * (4 + 1) - 3), 2) + max(2, 3, 4)', '13.5', 'Test round with mixed arithmetic and max'],
        ['round(max(3, 4) + (2^2 * 1.5), 2) - 1', '9', 'Test round and max with mixed arithmetic'],
        ['(round(3.5678, 2) + max(1, 2, 3)) * 2', '13.14', 'Test round with max and nested arithmetic'],
        ['2^3 + max(round(4.4, 1), 2.3, 1.1)', '12.4', 'Test exponentiation with round and max'],
        ['(2 + 3) * round((4 + 5) / 3, 1)', '15', 'Test nested arithmetic with round'],
        ['round(2 + (3 * max(1, 2, 3)), 2) - 1', '10', 'Test round with max and nested arithmetic'],
        ['round(max(2, 4, 6) + 3.5555, 2) * 2', '19.12', 'Test round and max with nested arithmetic'],
        ['2^round(3.5, 0) + max(1, 2, 3)', '19', 'Test exponentiation with round and max'],
        ['round((2 + 3) * 1.23456, 3)', '6.173', 'Test round with nested arithmetic'],
        ['round((5.678 / 2 + 1.2) * 2, 2)', '8.08', 'Test round with mixed arithmetic'],
        ['(round(2.555, 1) + max(1, 2, 3)) * 2 - 1', '10.2', 'Test round and max with mixed arithmetic'],
        ['round(max(4.4, 4.5, 4.6), 1) + (2.2^2)', '9.44', 'Test round with max and exponentiation'],
        ['(2 * 3 + 4) * round(1.2345, 2)', '12.3', 'Test nested arithmetic with round'],
        ['(2^3 * 1.5 + round(4.555, 2)) / max(1, 2, 3)', '5.51666666666667', 'Test exponentiation with round and max'],
        ['round(4.567 * (3 + 2), 2) - 5', '17.84', 'Test round with mixed arithmetic'],
        ['(round(2.5, 1) + max(1, 2, 3)) * 3', '16.5', 'Test round with max and nested arithmetic'],
        ['2 + (3 * round((4 - 1) / 2, 1))', '6.5', 'Test nested arithmetic with round'],
        ['round(2.5 + 3.5, 1) * max(1, 2, 3)', '18', 'Test round with max and nested arithmetic'],
        ['(2 + 3) * round(4.5678, 1) - max(1, 2, 3)', '20', 'Test nested arithmetic with round and max'],
        ['2^round(2.5, 0) + (3 * max(1, 2, 3))', '13', 'Test exponentiation with round and max'],
        ['round((3 + 2) * 1.678, 2) - 2', '6.39', 'Test round with mixed arithmetic'],
        ['(round(4.567, 2) + max(1, 2, 3)) * 1.5', '11.355', 'Test round with max and nested arithmetic'],
        ['(2^3 + round(3.14159, 2)) * max(1, 2, 3)', '33.42', 'Test exponentiation with round and max'],
        ['round(max(2, 3, 4) + 3.567, 2) - 1', '6.57', 'Test round with max and mixed arithmetic'],
        ['2 * (round(4.555, 2) + max(1, 2, 3))', '15.1', 'Test round with max and nested arithmetic'],
        ['round((2 + 3) * 2.345, 3) - 1', '10.725', 'Test round with nested arithmetic'],
        ['round(max(1, 2, 3) * 2.678, 2)', '8.03', 'Test round with max and multiplication'],
        ['2 + (3 * round(4.567, 2))', '15.71', 'Test nested arithmetic with round'],
        ['round(2.567 * max(1, 2, 3), 2) - 1', '6.7', 'Test round with max and mixed arithmetic'],
        ['(round(4.567, 2) + max(2, 4, 6)) / 2', '5.285', 'Test round with max and division'],
        ['(2 + 3) * round(4.555, 1) + max(1, 2, 3)', '26', 'Test nested arithmetic with round and max'],
        ['round((2^3 + 1.2345), 3)', '9.235', 'Test exponentiation with round'],
        ['round(max(3, 4, 5) + 2.555, 2) * 1.5', '11.325', 'Test round with max and multiplication'],
        ['2 * (3 + round(4.567, 2))', '15.14', 'Test round with mixed arithmetic'],
        ['round(3.5678 * max(1, 2, 3), 2) + 1', '11.7', 'Test round with max and mixed arithmetic'],
        ['(round(2.5, 1) + max(1, 3, 5)) * 2', '15', 'Test round with max and nested arithmetic'],
        ['2^round(2.5, 0) + (3 * 4.567)', '17.701', 'Test exponentiation with round and mixed arithmetic'],
        ['round((3 + 2) * 1.567, 2) - 1', '6.83', 'Test round with mixed arithmetic'],
        ['(round(4.555, 2) + max(2, 4, 6)) * 1.5', '15.825', 'Test round with max and multiplication'],
        ['round((2^3 + 3.567), 3) - max(1, 2, 3)', '8.567', 'Test exponentiation with round and max'],
        ['(2 * 3 + round(4.567, 2)) - max(1, 2, 3)', '7.57', 'Test round with mixed arithmetic and max'],
        ['2^round(max(1.5, 2.5, 3.5), 0) + 3', '19', 'Test exponentiation with round and max'],
        ['round(3.5678 + max(2, 3, 4), 3) * 2', '15.136', 'Test round with max and addition'],

        # Placeholder variables and string functions
        ['round({num}, 2)', '3.14', 'Test placeholder with round', { num => 3.14159 }],
        ['concat({a}, {b}, {c})', '\'Hello\'\' \'\'World\'', 'Test placeholder with concat', { a => '\'Hello\'', b => '\' \'', c => '\'World\'' }],
        ['substr({str}, 0, 5)', '\'Hell', 'Test placeholder with substr', { str => '\'Hello World\'' }],
        ['length({str})', '13', 'Test placeholder with length', { str => '\'Hello World\'' }],
        ['uc({str})', '\'HELLO\'', 'Test placeholder with uc', { str => '\'hello\'' }],
        ['concat("Hello"," ", "World")', 'Hello World', 'Test concat function with double quotes'],
        ['concat(\'Hello\', \' \', \'World\')', 'Hello World', 'Test concat function with single quotes'],
        ['substr("Hello World", 0, 5)', 'Hello', 'Test substr function with double quotes'],
        ['substr(\'Hello World\', 0, 5)', 'Hello', 'Test substr function with single quotes'],
        ['length("Hello World")', '11', 'Test length function with double quotes'],
        ['uc("hello")', 'HELLO', 'Test uc function with double quotes'],
        ['uc("\"hello\"")', '"HELLO"', 'Test uc function with single quotes'],
        ['length(\'Hello World\')', '11', 'Test length function with single quotes'],
        ['(round(4.567, 2) + max(1, 2, 3)) * 1.5', '11.355', 'Test round with max and nested arithmetic'],

        # Unary tests
        ['-3', '-3', 'Test single unary negation', {}],
        ['--3', '3', 'Test double unary negation', {}],
        ['-(-3)', '3', 'Test nested unary negation', {}],
        ['-(-(-3))', '-3', 'Test triple unary negation', {}],
        ['-3 + 2', '-1', 'Test unary negation with addition', {}],
        ['--3 + 5 * 2', '13', 'Test double unary negation and multiplication', {}],
        ['-(-3) + 5 * 2', '13', 'Test nested unary negation and multiplication', {}],
        ['-3 + 5 * 2', '7', 'Test unary negation with multiplication', {}],
        ['round(-3.14159, 2)', '-3.14', 'Test rounding with unary negation', {}],
        ['round(--3.14159, 2)', '3.14', 'Test rounding with double unary negation', {}],
        ['-(-(-(-5)))', '5', 'Test quadruple unary negation', {}],
        ['-2^2', '-4', 'Test unary negation with exponentiation', {}],
        ['-(-2)^2', '-4', 'Test nested unary negation with exponentiation', {}],
        ['-3 - 2', '-5', 'Test unary negation with subtraction', {}],
        ['--3 - 2', '1', 'Test double unary negation with subtraction', {}],
        ['-3 * 2', '-6', 'Test unary negation with multiplication', {}],
        ['--3 * 2', '6', 'Test double unary negation with multiplication', {}],
        ['-3 / 2', '-1.5', 'Test unary negation with division', {}],
        ['--3 / 2', '1.5', 'Test double unary negation with division', {}],
        ['-5 + 3', '-2', 'Test unary negation with addition', {}],
        ['--5 + 3', '8', 'Test double unary negation with addition', {}],
        ['-(-5) + 3', '8', 'Test nested unary negation with addition', {}],
        ['-5 - 3', '-8', 'Test unary negation with subtraction', {}],
        ['--5 - 3', '2', 'Test double unary negation with subtraction', {}],
        ['-(-5) - 3', '2', 'Test nested unary negation with subtraction', {}],
        ['-5 * 3', '-15', 'Test unary negation with multiplication', {}],
        ['--5 * 3', '15', 'Test double unary negation with multiplication', {}],
        ['-(-5) * 3', '15', 'Test nested unary negation with multiplication', {}],
        ['-5 / 3', '-1.66666666666667', 'Test unary negation with division', {}],
        ['--5 / 3', '1.66666666666667', 'Test double unary negation with division', {}],
        ['-(-5) / 3', '1.66666666666667', 'Test nested unary negation with division', {}],
        ['-5 + -3', '-8', 'Test unary negation with addition of negative numbers', {}],
        ['--5 + -3', '2', 'Test double unary negation with addition of negative numbers', {}],
        ['-(-5) + -3', '2', 'Test nested unary negation with addition of negative numbers', {}],
        ['-5 - -3', '-2', 'Test unary negation with subtraction of negative numbers', {}],
        ['--5 - -3', '8', 'Test double unary negation with subtraction of negative numbers', {}],
        ['-(-5) - -3', '8', 'Test nested unary negation with subtraction of negative numbers', {}],
        ['-5 * -3', '15', 'Test unary negation with multiplication of negative numbers', {}],
        ['--5 * -3', '-15', 'Test double unary negation with multiplication of negative numbers', {}],
        ['-(-5) * -3', '-15', 'Test nested unary negation with multiplication of negative numbers', {}],
        ['-5 / -3', '1.66666666666667', 'Test unary negation with division of negative numbers', {}],
        ['--5 / -3', '-1.66666666666667', 'Test double unary negation with division of negative numbers', {}],
        ['-(-5) / -3', '-1.66666666666667', 'Test nested unary negation with division of negative numbers', {}],
        ['-(-3) + -5 * 2', '-7', 'Test unary negation with mixed operations', {}],
        ['-(-3) - -5 * 2', '13', 'Test unary negation with mixed operations', {}],
        ['-(-3) * -5 / 2', '-7.5', 'Test unary negation with mixed operations', {}],

        # Additional complex expressions
        ['((2 + 3) * 4) - 5', '15', 'Test nested addition and multiplication with subtraction', {}],
        ['2 + (3 * (4 - (1 + 1)))', '8', 'Test deeply nested mixed operations', {}],
        ['((2 + 3) * (4 - 1)) / 2', '7.5', 'Test nested operations with division', {}],
        ['round((2.5 + 3.5) * (4 - 1), 2)', '18.00', 'Test nested addition and multiplication with rounding', {}],
        ['max(2, max(3, max(4, 5)))', '5', 'Test nested max functions', {}],
        ['-(-(-(-(2^3) + 4) * 2) / 3)', '2.66666666666667', 'Test deeply nested unary negations with mixed operations', {}],
        ['concat(concat("Hello", " "), concat("World", "!"))', 'Hello World!', 'Test nested concatenation', {}],
        ['round(max(1.2345, round(2.3456, 2)), 3)', '2.350', 'Test nested rounding and max', {}],
        ['length(concat("This ", "is ", concat("a ", "test.")))', '15', 'Test nested concatenation with length', {}],
        ['substr(concat("Hello", concat(" ", "World")), 1, 5)', 'ello ', 'Test nested concatenation with substr', {}],
        ['-(-(-(-(-(2^3) + round(4.567, 2)) * max(1, 2, 3)) / 3) + (round(3.14159, 2) * (5 + max(2, 3, 4))))', '-31.69', 'Test extremely nested and long expression with mixed operations', {}],
        ['round(max(round((5 * (2^3) - (10 / 2) + max(1, 2, 3)) + round(3.14159, 2)), 4.567), 2)', '41.00', 'Test nested functions with multiple rounds and max', {}],
        ['-(max((round(3.14159, 2) + max(2^3, 2, 4)) * 2, 5) - round((2^3 + 1) * 3, 1))', '4.72', 'Test nested max, round, and arithmetic operations', {}],
        ['max(2, round((5 + max(1, 2^3)) * round(4.567, 2), 2), 1)', '59.41', 'Test nested max with deeply nested round and arithmetic', {}],
        ['-round((round((round(3.14159, 2) + 2^3) * 4.567, 2) - max(1, 2, 3)) / 3, 2)', '-15.96', 'Test deeply nested rounds with arithmetic and max', {}],
        ['round(max((2^3 + 5), (round(4.567, 2) * 3), round((3.14159 + 2) * 2, 2)), 2)', '13.71', 'Test nested max with multiple rounds and arithmetic', {}],
        ['-(-(round(2^3 + round(4.567, 2), 2) * (max(1, 2, 3) + round(3.14159, 2))))', '77.1798', 'Test nested rounds and max with arithmetic', {}],
        ['max(round((2^3 + 1) * 3, 1), round((4.567 + round(3.14159, 2)), 2), max(1, 2, 3))', '27.0', 'Test nested max and round with arithmetic', {}],
        ['round(2^round(max(1, 2.5, 3), 1) + (max(2^2, 4) * round(4.567, 2)), 2)', '26.28', 'Test nested rounds and max with exponentiation and arithmetic', {}],
        ['-(-(-(round((2^3 + round(3.14159, 2)), 2) + (max(1, 2, 3) * round(4.567, 2))) / 3))', '-8.28333333333333', 'Test deeply nested rounds, max, and arithmetic', {}],
    );

    # Execute each test case
    foreach my $test (@tests) {
        my ($input, $expected, $description, $test_vars) = @$test;
        %vars = %$test_vars if $test_vars;
        my $result = calculate($input);
        is($result, $expected, $description);
    }

    done_testing();
}

run_tests();
