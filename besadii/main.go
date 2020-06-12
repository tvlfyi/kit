// Copyright 2019 Google LLC.
// SPDX-License-Identifier: Apache-2.0
//
// besadii is a small CLI tool that triggers depot builds on
// builds.sr.ht
//
// It is designed to run as a post-update git hook on the server
// hosting the depot.
package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"io/ioutil"
	"log/syslog"
	"net/http"
	"os"
	"os/exec"
	"strings"
)

var gitBin = "git"
var branchPrefix = "refs/heads/"

// This value is set by the git hook invocation when a branch is
// removed, builds should not be triggered in that case.
var deletedBranch = "0000000000000000000000000000000000000000"

// Represents an updated reference as passed to besadii by git
//
// https://git-scm.com/docs/githooks#pre-receive
type refUpdate struct {
	name string
	old  string
	new  string
}

// Represents a builds.sr.ht build object as described on
// https://man.sr.ht/builds.sr.ht/api.md
type Build struct {
	Manifest string   `json:"manifest"`
	Note     string   `json:"note"`
	Tags     []string `json:"tags"`
}

// Represents a build trigger object as described on <the docs for
// this are currently down>
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
func triggerBuild(log *syslog.Writer, token, branch, commit string) {
	build := Build{
		Manifest: prepareManifest(commit),
		Note:     fmt.Sprintf("Build of '%s' at '%s'", branch, commit),
		Tags: []string{
			// my branch names tend to contain slashes, which are not valid
			// identifiers in sourcehut.
			"depot", strings.ReplaceAll(branch, "/", "_"),
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
		fmt.Fprintf(log, "triggered builds.sr.ht job for branch '%s' at commit '%s'", branch, commit)
	}
}

func parseRefUpdates() ([]refUpdate, error) {
	var updates []refUpdate

	scanner := bufio.NewScanner(os.Stdin)
	for scanner.Scan() {
		line := scanner.Text()
		fragments := strings.Split(line, " ")

		if len(fragments) != 3 {
			return nil, fmt.Errorf("invalid ref update: '%s'", line)
		}

		update := refUpdate{
			old:  fragments[0],
			new:  fragments[1],
			name: fragments[2],
		}

		if strings.HasPrefix(update.name, branchPrefix) && update.new != deletedBranch {
			update.name = strings.TrimPrefix(update.name, branchPrefix)
			updates = append(updates, update)
		}
	}

	if err := scanner.Err(); err != nil {
		return nil, err
	}

	return updates, nil
}

func main() {
	log, err := syslog.New(syslog.LOG_INFO|syslog.LOG_USER, "besadii")
	if err != nil {
		fmt.Printf("failed to open syslog: %s\n", err)
		os.Exit(1)
	}

	// Before triggering builds, it is important that git
	// update-server-info is run so that cgit correctly serves the
	// repository.
	err = exec.Command(gitBin, "update-server-info").Run()
	if err != nil {
		log.Alert("failed to run 'git update-server-info' for depot!")
		os.Exit(1)
	}

	token, err := ioutil.ReadFile("/etc/secrets/srht-token")
	if err != nil {
		log.Alert("sourcehot token could not be read")
		os.Exit(1)
	}

	updates, err := parseRefUpdates()
	if err != nil {
		log.Err(fmt.Sprintf("could not parse updated refs:", err))
		os.Exit(1)
	}

	fmt.Fprintf(log, "triggering builds for %v refs", len(updates))

	for _, update := range updates {
		triggerBuild(log, string(token), update.name, update.new)
	}
}
