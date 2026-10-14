package main

import (
	"encoding/json"
	"github.com/p5/konflux-sandbox/prototypes/consumers/journal"
	"os"
)

func main() {
	var value any
	if err := json.NewDecoder(os.Stdin).Decode(&value); err != nil {
		panic(err)
	}
	if err := journal.Write(os.Args[1], value); err != nil {
		panic(err)
	}
}
