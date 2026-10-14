package main

import (
	"bufio"
	"encoding/json"
	"flag"
	"fmt"
	"os"
)

type state struct {
	Attempt      int    `json:"attempt"`
	Phase        string `json:"phase"`
	Outcome      string `json:"outcome"`
	Cancelled    bool   `json:"cancelled"`
	Cleanup      string `json:"cleanup"`
	Dispatches   int    `json:"observedDispatches"`
	Rejected     int    `json:"rejectedEvents"`
	RetryAllowed bool   `json:"retryAllowed"`
}

type event struct {
	Kind    string
	Attempt int
}

func initial() state {
	return state{Attempt: 1, Phase: "Pending", Outcome: "Pending", Cleanup: "NotAllocated"}
}

func reduce(s state, e event) state {
	if e.Attempt != 0 && e.Attempt != s.Attempt {
		s.Rejected++
		return s
	}
	if e.Kind == "retry" {
		if s.Outcome == "Pending" || s.Cleanup != "Complete" {
			s.Rejected++
			return s
		}
		n := initial()
		n.Attempt = s.Attempt + 1
		n.Dispatches = s.Dispatches
		n.Rejected = s.Rejected
		return n
	}
	switch e.Kind {
	case "allocate":
		if s.Phase != "Pending" || s.Cancelled {
			s.Rejected++
			break
		}
		s.Phase, s.Cleanup = "Allocated", "Required"
	case "dispatch":
		if s.Phase != "Allocated" || s.Cancelled {
			s.Rejected++
			break
		}
		s.Phase = "Dispatching"
		s.Dispatches++
	case "ack":
		if s.Phase != "Dispatching" || s.Cancelled {
			s.Rejected++
			break
		}
		s.Phase = "Running"
	case "success", "failure":
		if s.Cancelled || s.Outcome != "Pending" || (s.Phase != "Running" && s.Phase != "Dispatching") {
			s.Rejected++
			break
		}
		s.Phase = "Finished"
		s.Outcome = map[string]string{"success": "Passed", "failure": "CheckFailed"}[e.Kind]
	case "cancel", "timeout":
		if s.Outcome != "Pending" {
			s.Rejected++
			break
		}
		s.Cancelled, s.Phase = true, "Finished"
		s.Outcome = map[string]string{"cancel": "Cancelled", "timeout": "TimedOut"}[e.Kind]
		if s.Cleanup == "NotAllocated" {
			s.Cleanup = "Complete"
		}
	case "restart":
		if s.Phase == "Dispatching" || s.Phase == "Running" {
			s.Phase, s.Outcome = "Finished", "Unknown"
		}
	case "cleanup-failure":
		if s.Cleanup != "NotAllocated" {
			s.Cleanup = "Failed"
		}
	case "cleanup":
		if s.Outcome == "Pending" {
			s.Rejected++
			break
		}
		s.Cleanup = "Complete"
	default:
		s.Rejected++
	}
	s.RetryAllowed = s.Outcome != "Pending" && s.Cleanup == "Complete"
	return s
}

func show(label string, s state) {
	b, _ := json.MarshalIndent(s, "", "  ")
	fmt.Printf("%s\n%s\n", label, b)
}

func scenarios() {
	cases := []struct {
		name   string
		events []event
		check  func(state) bool
	}{
		{"normal", []event{{Kind: "allocate"}, {Kind: "dispatch"}, {Kind: "ack"}, {Kind: "success"}, {Kind: "cleanup"}}, func(s state) bool { return s.Outcome == "Passed" && s.Cleanup == "Complete" && s.Dispatches == 1 }},
		{"cancel-before-dispatch", []event{{Kind: "cancel"}, {Kind: "allocate"}, {Kind: "dispatch"}}, func(s state) bool { return s.Outcome == "Cancelled" && s.Dispatches == 0 }},
		{"late-success-after-cancel", []event{{Kind: "allocate"}, {Kind: "dispatch"}, {Kind: "ack"}, {Kind: "cancel"}, {Kind: "success"}, {Kind: "cleanup"}}, func(s state) bool { return s.Outcome == "Cancelled" && s.Rejected == 1 }},
		{"uncertain-dispatch-restart", []event{{Kind: "allocate"}, {Kind: "dispatch"}, {Kind: "restart"}, {Kind: "dispatch"}, {Kind: "success"}, {Kind: "cleanup"}}, func(s state) bool { return s.Outcome == "Unknown" && s.Dispatches == 1 && s.Rejected == 2 }},
		{"cleanup-failure", []event{{Kind: "allocate"}, {Kind: "dispatch"}, {Kind: "success"}, {Kind: "cleanup-failure"}, {Kind: "retry"}}, func(s state) bool { return s.Outcome == "Passed" && s.Cleanup == "Failed" && !s.RetryAllowed }},
		{"old-attempt-result", []event{{Kind: "allocate"}, {Kind: "dispatch"}, {Kind: "failure"}, {Kind: "cleanup"}, {Kind: "retry"}, {Kind: "allocate"}, {Kind: "dispatch"}, {Kind: "success", Attempt: 1}, {Kind: "success", Attempt: 2}, {Kind: "cleanup"}}, func(s state) bool {
			return s.Attempt == 2 && s.Outcome == "Passed" && s.Dispatches == 2 && s.Rejected == 1
		}},
		{"deadline", []event{{Kind: "allocate"}, {Kind: "dispatch"}, {Kind: "timeout"}, {Kind: "success"}, {Kind: "cleanup"}}, func(s state) bool { return s.Outcome == "TimedOut" && s.Rejected == 1 }},
	}
	for _, c := range cases {
		s := initial()
		show(c.name+" initial", s)
		for _, e := range c.events {
			s = reduce(s, e)
			show(c.name+" "+e.Kind, s)
		}
		if !c.check(s) {
			fmt.Fprintln(os.Stderr, "scenario failed:", c.name)
			os.Exit(1)
		}
	}
	fmt.Printf("PASS %d recovery scenarios; this is a proposed execution model, not Konflux controller behavior.\n", len(cases))
}

func main() {
	interactive := flag.Bool("interactive", false, "Drive the throwaway execution model by hand")
	flag.Parse()
	if !*interactive {
		scenarios()
		return
	}
	s := initial()
	scanner := bufio.NewScanner(os.Stdin)
	for {
		fmt.Print("\033[2J\033[H")
		show("PROTOTYPE execution state", s)
		fmt.Println("allocate dispatch ack success failure cancel timeout restart cleanup-failure cleanup retry reset quit")
		if !scanner.Scan() || scanner.Text() == "quit" {
			return
		}
		if scanner.Text() == "reset" {
			s = initial()
		} else {
			s = reduce(s, event{Kind: scanner.Text()})
		}
	}
}
