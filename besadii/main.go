// Copyright 2019-2020 Google LLC.
// SPDX-License-Identifier: Apache-2.0
//
// besadii is a small CLI tool that is invoked as a hook by various
// programs to cause CI-related actions.
//
// It supports the following modes & operations:
//
// Gerrit (ref-updated) hook:
// - Trigger Buildkite CI builds
// - Trigger SourceGraph (cs.tvl.fyi) repository index updates
//
// Buildkite (post-command) hook:
// - Submit CL verification status back to Gerrit
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
	"regexp"
)

var branchRegexp = regexp.MustCompile(`^refs/heads/(.*)$`)
var metaRegexp = regexp.MustCompile(`^refs/changes/\d{0,2}/(\d+)/meta$`)
var patchsetRegexp = regexp.MustCompile(`^refs/changes/\d{0,2}/(\d+)/(\d+)$`)

// refUpdated is a struct representing the information passed to
// besadii when it is invoked as Gerrit's refUpdated hook.
//
// https://gerrit.googlesource.com/plugins/hooks/+/HEAD/src/main/resources/Documentation/hooks.md#ref_updated
type refUpdated struct {
	project   string
	ref       string
	commit    string
	submitter string
	email     string

	changeId *string
	patchset *string
}

type Author struct {
	Name  string `json:"name"`
	Email string `json:"email"`
}

// Build is the representation of a Buildkite build as described on
// https://buildkite.com/docs/apis/rest-api/builds#create-a-build
type Build struct {
	Commit string            `json:"commit"`
	Branch string            `json:"branch"`
	Author Author            `json:"author"`
	Env    map[string]string `json:"env"`
}

// Trigger a build of a given branch & commit on Buildkite
func triggerBuild(log *syslog.Writer, token string, update *refUpdated) error {
	env := make(map[string]string)

	if update.changeId != nil && update.patchset != nil {
		env["GERRIT_CHANGE_ID"] = *update.changeId
		env["GERRIT_PATCHSET"] = *update.patchset
	}

	build := Build{
		Commit: update.commit,
		Branch: update.ref,
		Env:    env,
		Author: Author{
			Name:  update.submitter,
			Email: update.email,
		},
	}

	body, _ := json.Marshal(build)
	reader := ioutil.NopCloser(bytes.NewReader(body))

	req, err := http.NewRequest("POST", "https://api.buildkite.com/v2/organizations/tvl/pipelines/depot/builds", reader)
	if err != nil {
		return fmt.Errorf("failed to create an HTTP request: %w", err)
	}

	req.Header.Add("Authorization", "Bearer "+token)
	req.Header.Add("Content-Type", "application/json")

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		// This might indicate a temporary error on the Buildkite side.
		return fmt.Errorf("failed to send Buildkite request: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != 201 {
		respBody, _ := ioutil.ReadAll(resp.Body)
		log.Err(fmt.Sprintf("received non-success response from Buildkite: %s (%v)", respBody, resp.Status))
	} else {
		fmt.Fprintf(log, "triggered Buildkite build for ref %q at commit %q", update.ref, update.commit)
	}

	return nil
}

// Trigger a Sourcegraph repository index update on cs.tvl.fyi.
//
// https://docs.sourcegraph.com/admin/repo/webhooks
func triggerIndexUpdate(token string) error {
	req, err := http.NewRequest("POST", "https://cs.tvl.fyi/.api/repos/depot/-/refresh", nil)
	if err != nil {
		return err
	}

	req.Header.Add("Authorization", "token "+token)

	_, err = http.DefaultClient.Do(req)
	return err
}

func refUpdatedFromFlags() (*refUpdated, error) {
	var update refUpdated

	flag.StringVar(&update.project, "project", "", "Gerrit project")
	flag.StringVar(&update.commit, "newrev", "", "new revision")
	flag.StringVar(&update.email, "submitter", "", "Submitter email")
	flag.StringVar(&update.submitter, "submitter-username", "", "Submitter username")
	flag.StringVar(&update.ref, "refname", "", "updated reference name")

	// Gerrit passes more flags than we want, but Rob Pike decided[0] in
	// 2013 that the Go art project will not allow users to ignore flags
	// because he "doesn't like it". The following code ignores the
	// flags.
	//
	// [0]: https://github.com/golang/go/issues/6112#issuecomment-66083768
	var _old string
	flag.StringVar(&_old, "oldrev", "", "")

	flag.Parse()

	if update.project == "" || update.ref == "" || update.commit == "" || update.submitter == "" {
		// If we get here, the user is probably being a dummy and invoking
		// this manually - but incorrectly.
		return nil, fmt.Errorf("'ref-updated' hook invoked without required arguments")
	}

	if update.project != "depot" || metaRegexp.MatchString(update.ref) {
		// this is not an error, but also not something we handle.
		return nil, nil
	}

	if branchRegexp.MatchString(update.ref) {
		// these refs don't need special handling, just move on
		return &update, nil
	}

	if matches := patchsetRegexp.FindStringSubmatch(update.ref); matches != nil {
		update.changeId = &matches[1]
		update.patchset = &matches[2]
		return &update, nil
	}

	return nil, fmt.Errorf("besadii does not support updates for this type of ref (%q)", update.ref)
}

func refUpdatedMain() {
	// Logging happens in syslog for Gerrit hooks because we don't want
	// the hook output to be intermingled with Gerrit's own output
	// stream
	log, err := syslog.New(syslog.LOG_INFO|syslog.LOG_USER, "besadii")
	if err != nil {
		fmt.Fprintf(os.Stderr, "failed to open syslog: %s\n", err)
		os.Exit(1)
	}

	update, err := refUpdatedFromFlags()
	if err != nil {
		log.Err(fmt.Sprintf("failed to parse ref update: %s", err))
		os.Exit(1)
	}

	if update == nil { // the project was not 'depot'
		log.Err("build triggers are only supported for the 'depot' project")
		os.Exit(0)
	}

	buildkiteToken, err := ioutil.ReadFile("/etc/secrets/buildkite-besadii")
	if err != nil {
		log.Alert(fmt.Sprintf("buildkite token could not be read: %s", err))
		os.Exit(1)
	}

	sourcegraphToken, err := ioutil.ReadFile("/etc/secrets/sourcegraph-token")
	if err != nil {
		log.Alert(fmt.Sprintf("sourcegraph token could not be read: %s", err))
		os.Exit(1)
	}

	err = triggerBuild(log, string(buildkiteToken), update)
	if err != nil {
		log.Err(fmt.Sprintf("failed to trigger Buildkite build: %s", err))
	}

	err = triggerIndexUpdate(string(sourcegraphToken))
	if err != nil {
		log.Err(fmt.Sprintf("failed to trigger sourcegraph index update: %s", err))
	}
	log.Info("triggered sourcegraph index update")
}

// reviewInput is a struct representing the data submitted to Gerrit
// to post a review on a CL.
//
// https://gerrit-review.googlesource.com/Documentation/rest-api-changes.html#review-input
type reviewInput struct {
	Message                        string         `json:"message"`
	Labels                         map[string]int `json:"labels"`
	OmitDuplicateComments          bool           `json:"omit_duplicate_comments"`
	IgnoreDefaultAttentionSetRules bool           `json:"ignore_default_attention_set_rules"`
	Tag                            string         `json:"tag"`
}

func postCommandMain() {
	changeId := os.Getenv("GERRIT_CHANGE_ID")
	patchset := os.Getenv("GERRIT_PATCHSET")

	if changeId == "" || patchset == "" {
		// If these variables are unset, but the hook was invoked, the
		// build was most likely for a branch and not for a CL - no status
		// needs to be reported back to Gerrit!
		fmt.Println("This isn't a CL build, nothing to do. Have a nice day!")
		return
	}

	if os.Getenv("BUILDKITE_LABEL") != ":duck:" {
		// this is not the build stage, don't do anything.
		return
	}

	gerritPassword, err := ioutil.ReadFile("/etc/secrets/buildkite-gerrit")
	if err != nil {
		fmt.Fprintf(os.Stderr, "Gerrit password could not be read: %s", err)
		os.Exit(1)
	}

	var verified int
	var verb string

	if os.Getenv("BUILDKITE_COMMAND_EXIT_STATUS") == "0" {
		verified = 1 // Verified: +1 in Gerrit
		verb = "passed"
	} else {
		verified = -1
		verb = "failed"
	}

	msg := fmt.Sprintf("Build of patchset %s %s: %s", patchset, verb, os.Getenv("BUILDKITE_BUILD_URL"))
	review := reviewInput{
		Message:               msg,
		OmitDuplicateComments: true,
		Labels: map[string]int{
			"Verified": verified,
		},

		// Update the attention set if we are failing this patchset.
		IgnoreDefaultAttentionSetRules: verified == 1,

		Tag: "autogenerated:buildkite~result",
	}

	body, _ := json.Marshal(review)
	reader := ioutil.NopCloser(bytes.NewReader(body))

	url := fmt.Sprintf("https://cl.tvl.fyi/a/changes/%s/revisions/%s/review", changeId, patchset)
	req, err := http.NewRequest("POST", url, reader)
	if err != nil {
		fmt.Fprintf(os.Stderr, "failed to create an HTTP request: %w", err)
		os.Exit(1)
	}

	req.SetBasicAuth("buildkite", string(gerritPassword))
	req.Header.Add("Content-Type", "application/json")

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		fmt.Errorf("failed to update CL on Gerrit: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != 200 {
		respBody, _ := ioutil.ReadAll(resp.Body)
		fmt.Fprintf(os.Stderr, "received non-success response from Gerrit: %s (%v)", respBody, resp.Status)
	} else {
		fmt.Printf("Updated CI status on https://cl.tvl.fyi/c/depot/+/%s/%s", changeId, patchset)
	}
}

func main() {
	bin := path.Base(os.Args[0])

	if bin == "ref-updated" {
		refUpdatedMain()
	} else if bin == "post-command" {
		postCommandMain()
	} else {
		fmt.Fprintf(os.Stderr, "besadii does not know how to be invoked as %q, sorry!", bin)
		os.Exit(1)
	}
}
