# reTasker backend — a plain aarch64 executable with SQLite statically linked
# (the device ships no libsqlite3, so we vendor the amalgamation). Built with the
# ferrari SDK's cross-gcc, same as the capture extension. No Qt dependency.
objects = main.o sqlite3.o
name = retasker-backend

# Trim SQLite to what we use: single-threaded, no extension loading.
sqlite_flags = -DSQLITE_THREADSAFE=0 -DSQLITE_OMIT_LOAD_EXTENSION -DSQLITE_DEFAULT_MEMSTATUS=0

$(name) : $(objects)
	${CC} ${CFLAGS} -o $(name) $(objects) -lm

main.o : src/main.c vendor/sqlite3.h
	${CC} ${CFLAGS} -c -o $@ src/main.c

sqlite3.o : vendor/sqlite3.c vendor/sqlite3.h
	${CC} ${CFLAGS} $(sqlite_flags) -c -o $@ vendor/sqlite3.c

.PHONY  : clean
clean :
	rm -f $(name) $(objects)
