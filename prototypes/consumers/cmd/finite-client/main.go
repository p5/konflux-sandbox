package main

import (
	"github.com/p5/konflux-sandbox/prototypes/consumers/client"
	"os"
)

func main() { client.Run("finite", os.Args[1:]) }
