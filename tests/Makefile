ZIG:=zig

%.o: %.zig
	$(ZIG) build-obj -O ReleaseFast $<

build: main.o exit.o
	../zig-cache/bin/zld-elf $^

.PHONY: build
