// bitratebench maintains the core's 480i lease during isolated decoder tests.
// It is a development tool and is not included in release packages.
package main

import (
	"fmt"
	"os"
	"os/signal"
	"syscall"

	"plexcrt/internal/ring"
)

func main() {
	r, err := ring.Open()
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	defer r.Close()
	defer r.StartVideo(0, nil)()
	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM)
	<-stop
}
