module github.com/p5/konflux-sandbox/prototypes/consumers

go 1.26.0

require (
	github.com/p5/konflux-sandbox/prototypes/identity v0.0.0
	github.com/p5/konflux-sandbox/prototypes/private-evidence v0.0.0
)

replace github.com/p5/konflux-sandbox/prototypes/identity => ../identity

replace github.com/p5/konflux-sandbox/prototypes/private-evidence => ../private-evidence
