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
	"log"
	"net/http"
	"os"
	"strings"
)

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
		Sources: []string{"https://git.camden.tazj.in/"},

		// secret for cachix/tazjin
		Secrets: []string{"f7f02546-4d95-44f7-a98e-d61fdded8b5b"},

		Tasks: [](map[string]string){
			{"setup": `# sourcehut does not censor secrets in builds, hence this hack:
echo -n 'export CACHIX_SIGNING_KEY=' >> ~/.buildenv
cat ~/.cachix-tazjin >> ~/.buildenv
nix-env -iA third_party.cachix -f git.tazj.in
cachix use tazjin
cd git.tazj.in
git checkout ` + commit},

			{"build": `cd git.tazj.in
nix-build ci-builds.nix > built-paths`},

			{"cache": `cd git.tazj.in
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
func triggerBuild(token, branch, commit string) {
	build := Build{
		Manifest: prepareManifest(commit),
		Note:     fmt.Sprintf("Build of 'master' at '%s'", commit),
		Tags: []string{
			"depot", branch,
		},
	}

	body, _ := json.Marshal(build)
	reader := ioutil.NopCloser(bytes.NewReader(body))

	req, err := http.NewRequest("POST", "https://builds.sr.ht/api/jobs", reader)
	if err != nil {
		log.Fatalln("[ERROR] failed to create an HTTP request:", err)
	}

	req.Header.Add("Authorization", token)
	req.Header.Add("Content-Type", "application/json")

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		// This might indicate a temporary error on the sourcehut side, do
		// not fail the whole program.
		log.Println("failed to send builds.sr.ht request:", err)
		return
	}
	defer resp.Body.Close()

	if resp.StatusCode != 200 {
		respBody, err := ioutil.ReadAll(resp.Body)
		log.Printf("received non-success response from builds.sr.ht: %s (%v)[%s]", respBody, resp.Status, err)
	} else {
		log.Printf("triggered builds.sr.ht job for branch '%s' at commit '%s'", branch, commit)
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

		updates = append(updates, refUpdate{
			old:  fragments[0],
			new:  fragments[1],
			name: fragments[2],
		})
	}

	if err := scanner.Err(); err != nil {
		return nil, err
	}

	return updates, nil
}

func main() {
	token, err := ioutil.ReadFile("/etc/secrets/srht-token")
	if err != nil {
		log.Fatalln("[ERROR] sourcehot token could not be read")
	}

	updates, err := parseRefUpdates()
	if err != nil {
		log.Fatalln("[ERROR] could not parse updated refs:", err)
	}

	log.Printf("triggering builds for %v refs", len(updates))

	for _, update := range updates {
		triggerBuild(string(token), update.name, update.new)
	}
}
