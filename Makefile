CC       ?= cc
CFLAGS   ?= -O2 -Wall
LDLIBS    = -lm
TARGET    = mini-tcl
VERSION  ?= 0.2.1
PREFIX   ?= /usr/local
MINGW_CC ?= x86_64-w64-mingw32-gcc
MINILUA_URL = https://raw.githubusercontent.com/edubart/minilua/main/minilua.h

DIST_FILES = Makefile bin2c.c main.c mini-tcl.lua minilua.h \
             tests/smoke.tcl tests/smoke.expected tests/run-tests.sh

all: $(TARGET)

$(TARGET): main.c mini_tcl_script.h minilua.h
	$(CC) $(CFLAGS) -o $@ main.c $(LDLIBS)

mini_tcl_script.h: mini-tcl.lua bin2c
	./bin2c mini-tcl.lua mini_tcl_script > $@

bin2c: bin2c.c
	$(CC) $(CFLAGS) -o $@ bin2c.c

# Fetched once, then kept in the repo so offline builds work.
minilua.h:
	curl -fsSL -o $@ $(MINILUA_URL) || wget -qO $@ $(MINILUA_URL)

# Fully static Linux binary (no runtime .so dependencies at all).
static: mini-tcl-static
mini-tcl-static: main.c mini_tcl_script.h minilua.h
	$(CC) $(CFLAGS) -static -o $@ main.c $(LDLIBS)

# Windows cross-build (requires mingw-w64).
windows: $(TARGET).exe
$(TARGET).exe: main.c mini_tcl_script.h minilua.h
	$(MINGW_CC) $(CFLAGS) -o $@ main.c $(LDLIBS)

run: $(TARGET)
	./$(TARGET)

test: $(TARGET)
	sh tests/run-tests.sh ./$(TARGET)

install: $(TARGET)
	install -d $(DESTDIR)$(PREFIX)/bin
	install -s -m 755 $(TARGET) $(DESTDIR)$(PREFIX)/bin/$(TARGET)

uninstall:
	rm -f $(DESTDIR)$(PREFIX)/bin/$(TARGET)

dist: minilua.h
	mkdir -p $(TARGET)-$(VERSION)/tests
	cp Makefile bin2c.c main.c mini-tcl.lua minilua.h $(TARGET)-$(VERSION)/
	cp tests/smoke.tcl tests/smoke.expected tests/run-tests.sh $(TARGET)-$(VERSION)/tests/
	tar czf $(TARGET)-$(VERSION).tar.gz $(TARGET)-$(VERSION)
	rm -rf $(TARGET)-$(VERSION)

clean:
	rm -f $(TARGET) $(TARGET).exe mini-tcl-static bin2c mini_tcl_script.h \
	      $(TARGET)-*.tar.gz

.PHONY: all static windows run test install uninstall dist clean
