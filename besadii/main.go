// Copyright 2019-2020 Google LLC.
// SPDX-License-Identifier: Apache-2.0
//
// besadii is a small CLI tool that triggers depot builds on
// builds.sr.ht
//
// It is designed to run as a Gerrit hook (ref-updated).
package main

import (
	"bytes"
	"encoding/json"
	"flag"
	"fmt"
	"io/ioutil"
	"log/syslog"
	"net/http"
	"os"
	"path"
	"strings"
)

var branchPrefix = "refs/heads/"

// Represents an updated branch, as passed to besadii by Gerrit.
//
// https://gerrit.googlesource.com/plugins/hooks/+/HEAD/src/main/resources/Documentation/hooks.md#ref_updated
type branchUpdate struct {
	project   string
	branch    string
	commit    string
	submitter string
}

// Represents a builds.sr.ht build object as described on
// https://man.sr.ht/builds.sr.ht/api.md
type Build struct {
	Manifest string   `json:"manifest"`
	Note     string   `json:"note"`
	Tags     []string `json:"tags"`
}

// Represents a build trigger object as described on
// https://man.sr.ht/builds.sr.ht/triggers.md
type Trigger struct {
	Action    string `json:"action"`
	Condition string `json:"condition"`
	To        string `json:"to"`
}

// Represents a build manifest for sourcehut.
type Manifest struct {
	Image    string                `json:"image"`
	Sources  []string              `json:"sources"`
	Secrets  []string              `json:"secrets"`
	Tasks    [](map[string]string) `json:"tasks"`
	Triggers []Trigger             `json:"triggers"`
}

func prepareManifest(commit string) string {
	m := Manifest{
		Image:   "nixos/latest",
		Sources: []string{"https://code.tvl.fyi/"},

		// secret for cachix/tazjin
		Secrets: []string{"f7f02546-4d95-44f7-a98e-d61fdded8b5b"},

		Tasks: [](map[string]string){
			{"setup": `# sourcehut does not censor secrets in builds, hence this hack:
echo -n 'export CACHIX_SIGNING_KEY=' >> ~/.buildenv
cat ~/.cachix-tazjin >> ~/.buildenv
nix-env -iA third_party.cachix -f code.tvl.fyi
cachix use tazjin
cd code.tvl.fyi
git checkout ` + commit},

			{"build": `cd code.tvl.fyi
nix-build ci-builds.nix > built-paths`},

			{"cache": `cd code.tvl.fyi
cat built-paths | cachix push tazjin`},
		},

		Triggers: []Trigger{
			Trigger{Action: "email", Condition: "failure", To: "mail@tazj.in"},
		},
	}

	j, _ := json.Marshal(m)
	return string(j)
}

// Trigger a build of a given branch & commit on builds.sr.ht
func triggerBuild(log *syslog.Writer, token string, update *branchUpdate) {
	build := Build{
		Manifest: prepareManifest(update.commit),
		Note:     fmt.Sprintf("build of %q at %q, submitted by %q", update.branch, update.commit, update.submitter),
		Tags: []string{
			// my branch names tend to contain slashes, which are not valid
			// identifiers in sourcehut.
			"depot", strings.ReplaceAll(update.branch, "/", "_"),
		},
	}

	body, _ := json.Marshal(build)
	reader := ioutil.NopCloser(bytes.NewReader(body))

	req, err := http.NewRequest("POST", "https://builds.sr.ht/api/jobs", reader)
	if err != nil {
		log.Err(fmt.Sprintf("failed to create an HTTP request: %s", err))
		os.Exit(1)
	}

	req.Header.Add("Authorization", "token "+token)
	req.Header.Add("Content-Type", "application/json")

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		// This might indicate a temporary error on the sourcehut side, do
		// not fail the whole program.
		log.Err(fmt.Sprintf("failed to send builds.sr.ht request:", err))
		return
	}
	defer resp.Body.Close()

	if resp.StatusCode != 200 {
		respBody, _ := ioutil.ReadAll(resp.Body)
		log.Err(fmt.Sprintf("received non-success response from builds.sr.ht: %s (%v)", respBody, resp.Status))
	} else {
		fmt.Fprintf(log, "triggered builds.sr.ht job for branch %q at commit %q", update.branch, update.commit)
	}
}

func branchUpdateFromFlags() (*branchUpdate, error) {
	if path.Base(os.Args[0]) != "ref-updated" {
		return nil, fmt.Errorf("besadii must be invoked as the 'ref-updated' hook")
	}

	var update branchUpdate

	flag.StringVar(&update.project, "project", "", "Gerrit project")
	flag.StringVar(&update.commit, "newrev", "", "new revision")
	flag.StringVar(&update.submitter, "submitter-username", "", "Submitter username")
	ref := flag.String("refname", "", "updated reference name")

	// Gerrit passes more flags than we want, but Rob Pike decided[0] in
	// 2013 that the Go art project will not allow users to ignore flags
	// because he "doesn't like it". The following code ignores the
	// flags.
	//
	// [0]: https://github.com/golang/go/issues/6112#issuecomment-66083768
	var _old, _submitter string
	flag.StringVar(&_old, "oldrev", "", "")
	flag.StringVar(&_submitter, "submitter", "", "")

	flag.Parse()

	if update.project == "" || *ref == "" || update.commit == "" || update.submitter == "" {
		// If we get here, the user is probably being a dummy and invoking
		// this manually - but incorrectly.
		return nil, fmt.Errorf("'ref-updated' hook invoked without required arguments")
	}

	if update.project != "depot" {
		// this is not an error, but also not something we handle.
		return nil, nil
	}

	if !strings.HasPrefix(*ref, branchPrefix) {
		return nil, fmt.Errorf("besadii only supports branch updates at the moment")
	}

	update.branch = strings.TrimPrefix(*ref, branchPrefix)

	return &update, nil
}

func main() {
	log, err := syslog.New(syslog.LOG_INFO|syslog.LOG_USER, "besadii")
	if err != nil {
		fmt.Printf("failed to open syslog: %s\n", err)
		os.Exit(1)
	}

	token, err := ioutil.ReadFile("/etc/secrets/srht-token")
	if err != nil {
		log.Alert("sourcehot token could not be read")
		os.Exit(1)
	}

	update, err := branchUpdateFromFlags()
	if err != nil {
		log.Err(fmt.Sprintf("failed to parse ref update: %s", err))
		os.Exit(1)
	}

	if update == nil { // the project was not 'depot'
		os.Exit(0)
	}

	triggerBuild(log, string(token), update)
}
