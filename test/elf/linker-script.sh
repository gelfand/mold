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

cat <<EOF | $CC -o $t/a.o -c -xc -
#include <stdio.h>
int main() {
  printf("Hello world\n");
}
EOF

cat <<EOF > $t/script
GROUP("$t/a.o")
EOF

$CC -B. -o $t/exe $t/script
$QEMU $t/exe | grep -q 'Hello world'

$CC -B. -o $t/exe -Wl,-T,$t/script
$QEMU $t/exe | grep -q 'Hello world'

$CC -B. -o $t/exe -Wl,--script,$t/script
$QEMU $t/exe | grep -q 'Hello world'

echo OK
