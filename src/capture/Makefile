objects = main.o xovi.o

CC += -D_GNU_SOURCE -fPIC
VPATH = src
name = retasker-capture
xovifile = retasker-capture

$(name) : $(objects)
	${CC} ${CFLAGS} -shared -o $(name).so $(objects)

xovi.c xovi.h	&: $(xovifile).xovi
	python3 ${XOVI_REPO}/util/xovigen.py -o xovi.c -H xovi.h -a $(OECORE_TARGET_ARCH) $(xovifile).xovi

main.o	: xovi.h src/main.c vendor/stb_image_write.h

.PHONY  : clean
clean :
	rm -f $(name).so $(objects) xovi.c xovi.h
