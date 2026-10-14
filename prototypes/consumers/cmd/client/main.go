package main

import (
	"github.com/p5/konflux-sandbox/prototypes/consumers/client"
	"os"
)

func main() { client.Run(os.Args[1], os.Args[2:]) }
