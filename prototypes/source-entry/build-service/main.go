package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"syscall"

	comp "github.com/konflux-ci/application-api/api/konflux/v1alpha1"
	controllers "github.com/konflux-ci/build-service/internal/controller"
	"github.com/konflux-ci/build-service/pkg/boerrors"
	"github.com/konflux-ci/build-service/pkg/k8s"
	pac "github.com/openshift-pipelines/pipelines-as-code/pkg/apis/pipelinesascode/v1alpha1"
	core "k8s.io/api/core/v1"
	rbac "k8s.io/api/rbac/v1"
	meta "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/tools/events"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
)

func must(err error) {
	if err != nil {
		panic(err)
	}
}
func require(ok bool, what string) {
	if !ok {
		panic(what)
	}
}
func emit(v any) { must(json.NewEncoder(os.Stdout).Encode(v)) }

func component() *comp.Component {
	return &comp.Component{ObjectMeta: meta.ObjectMeta{Name: "local-source", Namespace: "source-entry-prototype", UID: types.UID("local-fixture")}, Spec: comp.ComponentSpec{Source: comp.ComponentSource{GitURL: "https://github.com/konflux-ci/application-api", Versions: []comp.ComponentVersion{{Name: "main", Revision: "main"}}}, ContainerImage: "registry.invalid/local/source"}}
}

func setup(c *comp.Component) (*controllers.ComponentBuildReconciler, client.Client) {
	s := runtime.NewScheme()
	must(core.AddToScheme(s))
	must(rbac.AddToScheme(s))
	must(comp.AddToScheme(s))
	must(pac.AddToScheme(s))
	k := fake.NewClientBuilder().WithScheme(s).WithStatusSubresource(&comp.Component{}).WithObjects(c).Build()
	r := &controllers.ComponentBuildReconciler{Client: k, Scheme: s, CredentialProvider: k8s.NewGitCredentialProvider(k), EventRecorder: events.NewFakeRecorder(100)}
	return r, k
}

func main() {
	ctx := context.Background()
	for _, tc := range []struct{ Name, URL, Image, Expected string }{
		{"no-source", "", "", "Nothing to do for component without git source; gitURL: "},
		{"missing-image", "https://github.com/konflux-ci/application-api", "", "waiting for spec.containerImage to be set"},
		{"missing-provider-configuration", "https://github.com/konflux-ci/application-api", "registry.invalid/local/source", "50: Pipelines as Code secret does not exist"},
		{"unknown-provider", "https://source.invalid/local/repository", "registry.invalid/local/source", "60:"},
	} {
		c := component()
		c.Spec.Source.GitURL = tc.URL
		c.Spec.ContainerImage = tc.Image
		r, k := setup(c)
		out, err := r.Reconcile(ctx, ctrl.Request{NamespacedName: client.ObjectKeyFromObject(c)})
		must(err)
		must(k.Get(ctx, client.ObjectKeyFromObject(c), c))
		require(strings.Contains(c.Status.Message, tc.Expected), "unexpected component status: "+c.Status.Message)
		var sa core.ServiceAccountList
		must(k.List(ctx, &sa, client.InNamespace(c.Namespace)))
		require(len(sa.Items) == 1, "build service account not ensured")
		var bindings rbac.RoleBindingList
		must(k.List(ctx, &bindings, client.InNamespace(c.Namespace)))
		require(len(bindings.Items) == 1, "build rolebinding not ensured")
		var repos pac.RepositoryList
		must(k.List(ctx, &repos, client.InNamespace(c.Namespace)))
		require(len(repos.Items) == 0, "repository onboarding unexpectedly succeeded")
		emit(map[string]any{"scenario": tc.Name, "componentStatus": c.Status, "reconcile": out, "serviceAccounts": len(sa.Items), "roleBindings": len(bindings.Items), "pacRepositories": len(repos.Items), "client": "in-memory Kubernetes client; no API server or manager"})
	}
	c := component()
	r, _ := setup(c)
	_, _, err := r.GetPacSecrets(ctx, c)
	bo, ok := errors.AsType[*boerrors.BuildOpError](err)
	require(ok && bo.GetErrorId() == 50, "missing provider error not exposed")
	emit(map[string]any{"scenario": "direct-missing-provider-error", "error": err.Error(), "errorID": bo.GetErrorId(), "persistent": bo.IsPersistent()})
	_, _, _, err = r.TriggerPaCBuildPreparation(ctx, c, []string{"main"})
	require(err != nil && strings.Contains(err.Error(), "PaC repository not found"), "missing repository accepted")
	emit(map[string]any{"scenario": "trigger-preparation-missing-repository", "error": err.Error()})
	var captured map[string]any
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		require(req.Method == http.MethodPost && req.URL.Path == "/incoming", "unexpected trigger target")
		must(json.NewDecoder(req.Body).Decode(&captured))
		http.Error(w, "local boundary fixture: provider authorization unavailable", http.StatusForbidden)
	}))
	defer server.Close()
	repo := &pac.Repository{ObjectMeta: meta.ObjectMeta{Name: "local-source", Namespace: c.Namespace}}
	err = r.TriggerPaCBuild(ctx, c, "main", "main", server.URL, &core.Secret{Data: map[string][]byte{}}, repo)
	require(err != nil && strings.Contains(err.Error(), "returned HTTP 403"), "denied incoming request accepted")
	require(captured["secret"] == "" && captured["branch"] == "main" && captured["repository"] == "local-source", "trigger shape changed")
	require(len(captured) == 6, "trigger has unexpected fields")
	params, ok := captured["params"].(map[string]any)
	require(ok && len(params) == 1 && params["source_url"] == c.Spec.Source.GitURL, "unexpected trigger params")
	emit(map[string]any{"scenario": "actual-trigger-post-to-local-denial-fixture", "payload": captured, "error": err.Error(), "receiver": "local HTTP fixture; not PaC authorization", "credentialsCreated": false})
	server.Close()
	err = r.TriggerPaCBuild(ctx, c, "main", "main", server.URL, &core.Secret{Data: map[string][]byte{}}, repo)
	expectation := os.Getenv("BUILD_SERVICE_TRANSPORT_EXPECTATION")
	if expectation == "nil" {
		require(err == nil, "historical transport reporting gap changed")
	} else {
		require(expectation == "" || expectation == "error", "unsupported transport expectation")
		require(errors.Is(err, syscall.ECONNREFUSED), "transport failure must preserve connection refusal")
	}
	var message any
	if err != nil {
		message = err.Error()
	}
	emit(map[string]any{"scenario": "actual-trigger-connection-refused", "methodError": message, "deliverySucceeded": false, "upstreamReturnsNilOnTransportError": err == nil, "endpoint": server.URL, "transportExpectation": expectation})
	fmt.Println("PASS source-entry Build Service scenarios; actual controller code with in-memory Kubernetes state, no GitHub API actions")
}
