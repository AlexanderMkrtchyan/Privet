package main

import (
	"log"
	"os/exec"
	"runtime"
)

// Thin Windows launcher: opens Privet in an Edge/Chrome app window.
func main() {
	const url = "https://messenger.banderdog.com"
	if runtime.GOOS == "windows" {
		candidates := [][]string{
			{"cmd", "/c", "start", "", "msedge", "--app=" + url},
			{"cmd", "/c", "start", "", "chrome", "--app=" + url},
			{"rundll32", "url.dll,FileProtocolHandler", url},
		}
		for _, c := range candidates {
			cmd := exec.Command(c[0], c[1:]...)
			if err := cmd.Start(); err == nil {
				return
			}
		}
		log.Fatal("could not open Privet — install Chrome or Edge")
	}
	_ = exec.Command("xdg-open", url).Start()
}
