#!/bin/bash
export LC_ALL=C
set -e
CC="${CC:-cc}"
CXX="${CXX:-c++}"
GCC="${GCC:-gcc}"
GXX="${GXX:-g++}"
OBJDUMP="${OBJDUMP:-objdump}"
MACHINE="${MACHINE:-$(uname -m)}"
testname=$(basename "$0" .sh)
echo -n "Testing $testname ... "
cd "$(dirname "$0")"/../..
mold="$(pwd)/mold"
t=out/test/elf/$testname
mkdir -p $t

echo 'int main() { return 0; }' | $CC -c -o $t/a.o -xc -
echo 'int main() { return 1; }' | $CC -c -o $t/b.o -xc -

! $CC -B. -o $t/exe $t/a.o $t/b.o 2> /dev/null || false
$CC -B. -o $t/exe $t/a.o $t/b.o -Wl,-allow-multiple-definition
$CC -B. -o $t/exe $t/a.o $t/b.o -Wl,-z,muldefs

echo OK
