show:	generate-pngs
	pqiv *.png

run:
	./dbus-bt-listener.pl | tee log-$$(date +%Y-%m-%d-%H:%M:%S)

generate-pngs:
	./drawit.sh

clean:
	rm *~

