# If you want to enable ASAN, run `make` with the following options:
#
# make CXXFLAGS='-fsanitize=address -g' LDFLAGS=-fsanitize=address USE_MIMALLOC=0

VERSION = 1.2.1

PREFIX = /usr/local
BINDIR = $(PREFIX)/bin
LIBDIR = $(PREFIX)/lib
LIBEXECDIR = $(PREFIX)/libexec
MANDIR = $(PREFIX)/share/man

INSTALL = install
INSTALL_PROGRAM = $(INSTALL)
INSTALL_DATA = $(INSTALL) -m 644

D = $(DESTDIR)

# CXX defaults to `g++`. Rewrite it with a vendor-neutral compiler
# name `c++`.
ifeq ($(origin CXX), default)
  CXX = c++
endif

# Allow overriding pkg-config binary
PKG_CONFIG = pkg-config

# If you want to keep symbols in the installed binary, run make with
# `STRIP=true` to run /bin/true instead of the strip command.
STRIP = strip

SRCS = $(wildcard *.cc elf/*.cc macho/*.cc)
OBJS = $(SRCS:%.cc=out/%.o)

OS := $(shell uname -s)
ARCH := $(shell uname -m)

IS_ANDROID = 0
ifneq ($(findstring -android,$(shell $(CC) -dumpmachine)),)
  IS_ANDROID = 1
endif

# If you want to compile mold for debugging, invoke make as
# `make CXXFLAGS=-g`.
CFLAGS = -O2
CXXFLAGS = -O2

MOLD_CXXFLAGS := -std=c++20 -fno-exceptions -fno-unwind-tables \
                 -fno-asynchronous-unwind-tables -Ithird-party/xxhash \
                 -DMOLD_VERSION=\"$(VERSION)\" -DLIBDIR="\"$(LIBDIR)\""

MOLD_LDFLAGS := -pthread -lz -lm -ldl

GIT_HASH := $(shell [ -d .git ] && git rev-parse HEAD)
ifneq ($(GIT_HASH),)
  MOLD_CXXFLAGS += -DGIT_HASH=\"$(GIT_HASH)\"
endif

LTO = 0
ifeq ($(LTO), 1)
  CXXFLAGS += -flto -O3
  LDFLAGS  += -flto
endif

# By default, we want to use mimalloc as a memory allocator. mimalloc
# is disabled on macOS and Android because it didn't work on those hosts.
USE_MIMALLOC = 1
ifeq ($(OS), Darwin)
  USE_MIMALLOC = 0
else ifeq ($(IS_ANDROID), 1)
  USE_MIMALLOC = 0
endif

ifeq ($(USE_MIMALLOC), 1)
  ifdef SYSTEM_MIMALLOC
    MOLD_CXXFLAGS += -DUSE_SYSTEM_MIMALLOC
    MOLD_LDFLAGS += -lmimalloc
  else
    MIMALLOC_LIB = out/mimalloc/libmimalloc.a
    MOLD_CXXFLAGS += -Ithird-party/mimalloc/include
    MOLD_LDFLAGS += -Wl,-whole-archive $(MIMALLOC_LIB) -Wl,-no-whole-archive
  endif
endif

ifdef SYSTEM_TBB
  MOLD_LDFLAGS += -ltbb
else
  TBB_LIB = out/tbb/libs/libtbb.a
  MOLD_LDFLAGS += $(TBB_LIB)
  MOLD_CXXFLAGS += -Ithird-party/tbb/include
endif

ifeq ($(OS), Linux)
  ifeq ($(IS_ANDROID), 0)
    # glibc before 2.17 need librt for clock_gettime
    MOLD_LDFLAGS += -Wl,-push-state -Wl,-as-needed -lrt -Wl,-pop-state
  endif
endif

NEEDS_LIBCRYPTO = 0
ifneq ($(OS), Darwin)
  NEEDS_LIBCRYPTO = 1
endif

ifeq ($(NEEDS_LIBCRYPTO), 1)
  MOLD_CXXFLAGS += $(shell $(PKG_CONFIG) --cflags-only-I openssl)
  MOLD_LDFLAGS += $(shell $(PKG_CONFIG) --libs-only-L openssl) -lcrypto
endif

# '-latomic' flag is needed building on riscv64 system
# RV32 system doesn't tested yet
# seems like '-atomic' would be better but not working.
ifeq ($(ARCH), riscv64)
  MOLD_LDFLAGS += -latomic
endif

# -Wc++11-narrowing is a fatal error on Android, so disable it.
ifeq ($(IS_ANDROID), 1)
  MOLD_CXXFLAGS += -Wno-c++11-narrowing
endif

ifeq ($(OS), Linux)
  MOLD_WRAPPER_LDFLAGS = -Wl,-push-state -Wl,-no-as-needed -ldl -Wl,-pop-state
endif

DEPFLAGS = -MT $@ -MMD -MP -MF out/$*.d

all: mold mold-wrapper.so

-include $(SRCS:%.cc=out/%.d)

mold: $(OBJS) $(MIMALLOC_LIB) $(TBB_LIB)
	$(CXX) $(OBJS) -o $@ $(MOLD_LDFLAGS) $(LDFLAGS)
	ln -sf mold ld
	ln -sf mold ld64.mold

mold-wrapper.so: elf/mold-wrapper.c
	$(CC) $(DEPFLAGS) $(CFLAGS) -fPIC -shared -o $@ $< $(MOLD_WRAPPER_LDFLAGS) $(LDFLAGS)

out/%.o: %.cc out/elf/.keep out/macho/.keep
	$(CXX) $(MOLD_CXXFLAGS) $(DEPFLAGS) $(CXXFLAGS) -c -o $@ $<

out/elf/.keep out/macho/.keep:
	mkdir -p $(@D)
	touch $@

$(MIMALLOC_LIB):
	mkdir -p out/mimalloc
	(cd out/mimalloc; CFLAGS=-DMI_USE_ENVIRON=0 cmake -G'Unix Makefiles' ../../third-party/mimalloc)
	$(MAKE) -C out/mimalloc mimalloc-static

$(TBB_LIB):
	mkdir -p out/tbb
	(cd out/tbb; cmake -G'Unix Makefiles' -DBUILD_SHARED_LIBS=OFF -DTBB_TEST=OFF -DCMAKE_CXX_FLAGS="$(CXXFLAGS) -D__TBB_DYNAMIC_LOAD_ENABLED=0" -DTBB_STRICT=OFF ../../third-party/tbb)
	$(MAKE) -C out/tbb tbb
	(cd out/tbb; ln -sf *_relwithdebinfo libs)

test tests check: all
ifeq ($(OS), Darwin)
	$(MAKE) -C test -f Makefile.darwin --no-print-directory
else
	$(MAKE) -C test -f Makefile.linux --no-print-directory --output-sync
endif
	@if test -t 1; then \
	  printf '\e[32mPassed all tests\e[0m\n'; \
	else \
	  echo 'Passed all tests'; \
	fi

test-x86-64: all
	@echo x86_64
	CC=x86_64-linux-gnu-gcc CXX=x86_64-linux-gnu-g++ GCC=x86_64-linux-gnu-gcc GXX=x86_64-linux-gnu-g++ OBJDUMP=x86_64-linux-gnu-objdump MACHINE=x86_64 QEMU='qemu-x86_64 -L /usr/x86_64-linux-gnu' $(MAKE) test

test-i386: all
	@echo i386
	CC=i686-linux-gnu-gcc CXX=i686-linux-gnu-g++ GCC=i686-linux-gnu-gcc GXX=i686-linux-gnu-g++ OBJDUMP=x86_64-linux-gnu-objdump MACHINE=i386 QEMU='qemu-i386 -L /usr/i686-linux-gnu' $(MAKE) test

test-arm64: all
	@echo arm64
	CC=aarch64-linux-gnu-gcc CXX=aarch64-linux-gnu-g++ GCC=aarch64-linux-gnu-gcc GXX=aarch64-linux-gnu-g++ OBJDUMP=aarch64-linux-gnu-objdump MACHINE=aarch64 QEMU='qemu-aarch64 -L /usr/aarch64-linux-gnu' $(MAKE) test

test-arm32: all
	@echo arm
	CC=arm-linux-gnueabihf-gcc CXX=arm-linux-gnueabihf-g++ GCC=arm-linux-gnueabihf-gcc GXX=arm-linux-gnueabihf-g++ OBJDUMP=arm-linux-gnueabihf-objdump MACHINE=arm QEMU='qemu-arm -L /usr/arm-linux-gnueabihf' $(MAKE) test

test-riscv64: all
	@echo riscv64
	CC=riscv64-linux-gnu-gcc CXX=riscv64-linux-gnu-g++ GCC=riscv64-linux-gnu-gcc GXX=riscv64-linux-gnu-g++ OBJDUMP=riscv64-linux-gnu-objdump MACHINE=riscv64 QEMU='qemu-riscv64 -L /usr/riscv64-linux-gnu' $(MAKE) test

test-all:
	$(MAKE) test-x86-64
	$(MAKE) test-i386
	$(MAKE) test-arm64
	$(MAKE) test-arm32
	$(MAKE) test-riscv64

install: all
	$(INSTALL) -d $D$(BINDIR)
	$(INSTALL_PROGRAM) mold $D$(BINDIR)
	$(STRIP) $D$(BINDIR)/mold

	$(INSTALL) -d $D$(LIBDIR)/mold
	$(INSTALL_DATA) mold-wrapper.so $D$(LIBDIR)/mold
	$(STRIP) $D$(LIBDIR)/mold/mold-wrapper.so

	$(INSTALL) -d $D$(LIBEXECDIR)/mold

# We want to make a symblink with a relative path, so that users can
# move the entire directory to other place without breaking the reference.
# GNU ln supports `--relative` to do that, but that's not supported by
# non-GNU systems. So we use Python to compute a relative path.
	ln -sf `python3 -c "import os.path; print(os.path.relpath('$(BINDIR)/mold', '$(LIBEXECDIR)/mold'))"` $D$(LIBEXECDIR)/mold/ld

	$(INSTALL) -d $D$(MANDIR)/man1
	$(INSTALL_DATA) docs/mold.1 $D$(MANDIR)/man1

	ln -sf mold $D$(BINDIR)/ld.mold
	ln -sf mold $D$(BINDIR)/ld64.mold

uninstall:
	rm -f $D$(BINDIR)/mold $D$(BINDIR)/ld.mold $D$(BINDIR)/ld64.mold
	rm -f $D$(MANDIR)/man1/mold.1
	rm -rf $D$(LIBDIR)/mold

clean:
	rm -rf *~ mold mold-wrapper.so out ld ld64.mold mold-*-linux.tar.gz

.PHONY: all test tests check clean test-x86-64 test-i386 test-arm64 test-arm32 test-riscv64 test-all
