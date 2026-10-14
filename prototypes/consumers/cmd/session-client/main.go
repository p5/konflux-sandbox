package main

import (
	"github.com/p5/konflux-sandbox/prototypes/consumers/client"
	"os"
)

func main() { client.Run("session", os.Args[1:]) }
