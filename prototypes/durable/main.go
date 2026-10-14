package main

import (
	"context"
	"crypto/rand"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"log"
	"os"
	"os/exec"
	"os/signal"
	"slices"
	"strconv"
	"strings"
	"syscall"
	"time"

	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/client-go/dynamic"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/tools/clientcmd"
	"k8s.io/client-go/tools/leaderelection"
	"k8s.io/client-go/tools/leaderelection/resourcelock"
)

const finalizer = "foundation.sandbox.p5.dev/cleanup"
const node = "konflux-sandbox-vm-prototype-control-plane"

var executionGVR = schema.GroupVersionResource{Group: "foundation.sandbox.p5.dev", Version: "v1alpha1", Resource: "executions"}

type Spec struct {
	OwnerID       string            `json:"ownerID"`
	AttemptID     string            `json:"attemptID"`
	SourceDigest  string            `json:"sourceDigest"`
	ProfileDigest string            `json:"profileDigest"`
	Image         string            `json:"image"`
	Command       []string          `json:"command"`
	Env           map[string]string `json:"env,omitempty"`
	Deadline      time.Time         `json:"deadline"`
	Mode          string            `json:"mode"`
	Cancel        bool              `json:"cancel,omitzero"`
}

type Status struct {
	Phase               string     `json:"phase"`
	Reason              string     `json:"reason,omitempty"`
	AttemptID           string     `json:"attemptID,omitempty"`
	ChildName           string     `json:"childName,omitempty"`
	ChildUID            string     `json:"childUID,omitempty"`
	RuntimeSandboxID    string     `json:"runtimeSandboxID,omitempty"`
	ImageID             string     `json:"imageID,omitempty"`
	GuestKernel         string     `json:"guestKernel,omitempty"`
	ExitCode            *int32     `json:"exitCode,omitempty"`
	DispatchCommittedAt *time.Time `json:"dispatchCommittedAt,omitempty"`
	VMObserved          bool       `json:"vmObserved,omitzero"`
	Adopted             bool       `json:"adopted,omitzero"`
	CleanupComplete     bool       `json:"cleanupComplete,omitzero"`
	CleanupUnverified   bool       `json:"cleanupUnverified,omitzero"`
	RecoveryBinding     string     `json:"recoveryBinding,omitempty"`
}

type Observation struct {
	SandboxID string `json:"sandboxID,omitempty"`
	PodUID    string `json:"podUID,omitempty"`
	Ready     bool   `json:"ready"`
	VMPIDs    []int  `json:"vmPIDs"`
}

type Controller struct {
	kube           kubernetes.Interface
	objects        dynamic.ResourceInterface
	namespace      string
	fault          string
	faultName      string
	schedulingGate bool
}

func main() {
	kubeconfig := flag.String("kubeconfig", "", "Dedicated VM cluster kubeconfig")
	contextName := flag.String("context", "kind-konflux-sandbox-vm-prototype", "Exact VM prototype context")
	namespace := flag.String("namespace", "foundation-durable-prototype", "Owned prototype namespace")
	guard := flag.String("guard", "", "Absolute path to local cluster guard")
	fault := flag.String("crash-at", "", "before-intent, after-intent, or after-create")
	faultName := flag.String("fault-execution", "", "Execution for crash injection")
	observeName := flag.String("observe-child", "", "Observe one child instead of controlling")
	observeUID := flag.String("observe-uid", "", "Pod UID for runtime observation")
	observeID := flag.String("observe-runtime-id", "", "Known CRI sandbox ID")
	recoverName := flag.String("recover-execution", "", "Trusted recovery: attach independently recorded runtime binding")
	watchdog := flag.Bool("watchdog", false, "Watch cancellation and absolute deadlines without dispatch authority")
	schedulingGate := flag.Bool("scheduling-gate", false, "Inject a scheduling delay for the bounded deadline scenario")
	flag.Parse()
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	if *contextName != "kind-konflux-sandbox-vm-prototype" || *guard == "" {
		log.Fatal("exact VM context and local guard required")
	}
	check := exec.CommandContext(ctx, "bash", *guard)
	check.Env = append(os.Environ(), "KUBECONFIG="+*kubeconfig, "KUBE_CONTEXT="+*contextName)
	if output, err := check.CombinedOutput(); err != nil {
		log.Fatalf("cluster guard: %v %s", err, output)
	}
	if *observeName != "" {
		observation, err := observe(ctx, *namespace, *observeName, *observeUID, *observeID)
		if err != nil {
			log.Fatal(err)
		}
		_ = json.NewEncoder(os.Stdout).Encode(observation)
		return
	}
	loader := clientcmd.NewNonInteractiveDeferredLoadingClientConfig(&clientcmd.ClientConfigLoadingRules{ExplicitPath: *kubeconfig}, &clientcmd.ConfigOverrides{CurrentContext: *contextName})
	config, err := loader.ClientConfig()
	if err != nil {
		log.Fatal(err)
	}
	config.Timeout = 10 * time.Second
	kube, err := kubernetes.NewForConfig(config)
	if err != nil {
		log.Fatal(err)
	}
	objects, err := dynamic.NewForConfig(config)
	if err != nil {
		log.Fatal(err)
	}
	ns, err := kube.CoreV1().Namespaces().Get(ctx, *namespace, metav1.GetOptions{})
	if err != nil || ns.Labels["foundation.sandbox.p5.dev/owner"] != "durable" {
		log.Fatalf("owned prototype namespace required: %v", err)
	}
	c := &Controller{kube: kube, objects: objects.Resource(executionGVR).Namespace(*namespace), namespace: *namespace, fault: *fault, faultName: *faultName, schedulingGate: *schedulingGate}
	if *watchdog {
		c.watch(ctx)
		return
	}
	if *recoverName != "" {
		if *observeUID == "" || *observeID == "" {
			log.Fatal("trusted recovery requires independently recorded Pod UID and runtime sandbox ID")
		}
		object, err := c.objects.Get(ctx, *recoverName, metav1.GetOptions{})
		if err != nil {
			log.Fatal(err)
		}
		var status Status
		if err := decode(object.Object["status"], &status); err != nil {
			log.Fatal(err)
		}
		if status.Phase != "UnknownOutcome" || !status.CleanupUnverified {
			log.Fatal("unverified unknown execution required")
		}
		status.ChildUID, status.RuntimeSandboxID = *observeUID, *observeID
		status.RecoveryBinding = "trusted-operator-record"
		if err := c.putStatus(ctx, object, status); err != nil {
			log.Fatal(err)
		}
		return
	}
	identity := "controller-" + rand.Text()
	lock := &resourcelock.LeaseLock{LeaseMeta: metav1.ObjectMeta{Name: "durable-controller", Namespace: *namespace}, Client: kube.CoordinationV1(), LockConfig: resourcelock.ResourceLockConfig{Identity: identity}}
	leaderelection.RunOrDie(ctx, leaderelection.LeaderElectionConfig{
		Lock: lock, LeaseDuration: 15 * time.Second, RenewDeadline: 10 * time.Second, RetryPeriod: 2 * time.Second, ReleaseOnCancel: true,
		Callbacks: leaderelection.LeaderCallbacks{
			OnStartedLeading: func(leading context.Context) { log.Printf("leader=%s", identity); c.run(leading) },
			OnStoppedLeading: func() { log.Print("leadership stopped") },
		},
	})
}

func (c *Controller) run(ctx context.Context) {
	for {
		objects, err := c.objects.List(ctx, metav1.ListOptions{})
		if err == nil {
			for i := range objects.Items {
				if err := c.reconcile(ctx, &objects.Items[i]); err != nil && !apierrors.IsConflict(err) && !apierrors.IsNotFound(err) {
					log.Printf("execution=%s error=%v", objects.Items[i].GetName(), err)
				}
			}
		} else if ctx.Err() == nil {
			log.Printf("list: %v", err)
		}
		select {
		case <-ctx.Done():
			return
		case <-time.After(250 * time.Millisecond):
		}
	}
}

func (c *Controller) reconcile(ctx context.Context, object *unstructured.Unstructured) error {
	var spec Spec
	var status Status
	if err := decode(object.Object["spec"], &spec); err != nil {
		return err
	}
	if object.Object["status"] != nil {
		if err := decode(object.Object["status"], &status); err != nil {
			return err
		}
	}
	if status.CleanupComplete {
		return c.removeFinalizer(ctx, object)
	}
	if !slices.Contains(object.GetFinalizers(), finalizer) {
		object.SetFinalizers(append(object.GetFinalizers(), finalizer))
		_, err := c.objects.Update(ctx, object, metav1.UpdateOptions{})
		return err
	}
	if status.Phase == "" {
		status = Status{Phase: "Allocating", AttemptID: spec.AttemptID, ChildName: "exec-" + string(object.GetUID()) + "-" + spec.AttemptID}
		if err := c.putStatus(ctx, object, status); err != nil {
			return err
		}
		c.crash(object, "before-intent")
		return nil
	}
	if !terminal(status.Phase) && (spec.Cancel || object.GetDeletionTimestamp() != nil) {
		status.Phase, status.Reason = "Cancelled", "ExternalCancellation"
		return c.putStatus(ctx, object, status)
	}
	if !terminal(status.Phase) && time.Now().After(spec.Deadline) {
		status.Phase, status.Reason = "DeadlineExceeded", "AbsoluteDeadline"
		return c.putStatus(ctx, object, status)
	}
	if terminal(status.Phase) {
		return c.cleanup(ctx, object, status)
	}
	pod, err := c.kube.CoreV1().Pods(c.namespace).Get(ctx, status.ChildName, metav1.GetOptions{})
	if apierrors.IsNotFound(err) {
		if status.DispatchCommittedAt != nil {
			status.Phase, status.Reason = "UnknownOutcome", "CommittedDispatchChildMissing"
			return c.putStatus(ctx, object, status)
		}
		now := time.Now().UTC()
		status.DispatchCommittedAt, status.Phase = &now, "DispatchCommitted"
		if err := c.putStatus(ctx, object, status); err != nil {
			return err
		}
		c.crash(object, "after-intent")
		desired := childPod(object, spec, status)
		if c.schedulingGate {
			desired.Spec.SchedulingGates = []corev1.PodSchedulingGate{{Name: "foundation.sandbox.p5.dev/prototype-delay"}}
		}
		pod, err = c.kube.CoreV1().Pods(c.namespace).Create(ctx, desired, metav1.CreateOptions{})
		if err != nil {
			return fmt.Errorf("uncertain create; next reconcile must adopt or fail, never replay: %w", err)
		}
		c.crash(object, "after-create")
		status.ChildUID, status.Phase = string(pod.UID), "Starting"
		return c.putStatus(ctx, object, status)
	}
	if err != nil {
		return err
	}
	if !owned(object, pod) || (status.ChildUID != "" && status.ChildUID != string(pod.UID)) {
		status.Phase, status.Reason = "Rejected", "ChildOwnershipConflict"
		return c.putStatus(ctx, object, status)
	}
	if len(pod.Spec.Containers) != 1 || pod.Spec.Containers[0].Image != spec.Image || !slices.Equal(pod.Spec.Containers[0].Command, spec.Command) || pod.Spec.RuntimeClassName == nil || *pod.Spec.RuntimeClassName != "kata-prototype" {
		status.Phase, status.Reason = "Rejected", "ChildSpecMismatch"
		return c.putStatus(ctx, object, status)
	}
	if status.ChildUID == "" {
		status.ChildUID, status.Adopted = string(pod.UID), true
		status.Reason = "AdoptedExistingChild"
	}
	observation, err := observe(ctx, c.namespace, pod.Name, string(pod.UID), status.RuntimeSandboxID)
	if err != nil {
		return err
	}
	if observation.SandboxID != "" {
		status.RuntimeSandboxID = observation.SandboxID
	}
	status.VMObserved = status.VMObserved || len(observation.VMPIDs) > 0
	for _, container := range pod.Status.ContainerStatuses {
		status.ImageID = container.ImageID
		if container.State.Terminated != nil {
			status.ExitCode = new(container.State.Terminated.ExitCode)
		}
	}
	switch pod.Status.Phase {
	case corev1.PodRunning:
		status.Phase = "Running"
	case corev1.PodSucceeded:
		status.Phase, status.Reason = "Succeeded", "ContainerExitZero"
	case corev1.PodFailed:
		status.Phase, status.Reason = "Failed", pod.Status.Reason
	default:
		status.Phase = "Starting"
	}
	if terminal(status.Phase) {
		logs, err := c.kube.CoreV1().Pods(c.namespace).GetLogs(pod.Name, &corev1.PodLogOptions{Container: "guest", LimitBytes: new(int64(8192))}).DoRaw(ctx)
		if err == nil {
			for line := range strings.SplitSeq(string(logs), "\n") {
				if kernel, ok := strings.CutPrefix(line, "GUEST_KERNEL="); ok {
					status.GuestKernel = kernel
				}
			}
		}
	}
	return c.putStatus(ctx, object, status)
}

func (c *Controller) cleanup(ctx context.Context, object *unstructured.Unstructured, status Status) error {
	pod, err := c.kube.CoreV1().Pods(c.namespace).Get(ctx, status.ChildName, metav1.GetOptions{})
	if err == nil {
		if !owned(object, pod) || (status.ChildUID != "" && status.ChildUID != string(pod.UID)) {
			if status.DispatchCommittedAt != nil {
				return errors.New("cleanup blocked by foreign child; operator resolution required")
			}
			status.CleanupComplete = true
			return c.putStatus(ctx, object, status)
		}
		if status.ChildUID == "" {
			status.ChildUID = string(pod.UID)
			return c.putStatus(ctx, object, status)
		}
		observation, err := observe(ctx, c.namespace, pod.Name, string(pod.UID), status.RuntimeSandboxID)
		if err != nil {
			return err
		}
		if observation.SandboxID != "" && status.RuntimeSandboxID == "" {
			status.RuntimeSandboxID = observation.SandboxID
			status.VMObserved = len(observation.VMPIDs) > 0
			return c.putStatus(ctx, object, status)
		}
		if pod.DeletionTimestamp == nil {
			return c.kube.CoreV1().Pods(c.namespace).Delete(ctx, pod.Name, metav1.DeleteOptions{GracePeriodSeconds: new(int64(1)), Preconditions: &metav1.Preconditions{UID: new(pod.UID)}})
		}
		return nil
	}
	if !apierrors.IsNotFound(err) {
		return err
	}
	observation, err := observe(ctx, c.namespace, status.ChildName, status.ChildUID, status.RuntimeSandboxID)
	if err != nil {
		return err
	}
	if observation.SandboxID != "" && status.RuntimeSandboxID == "" {
		status.RuntimeSandboxID, status.ChildUID = observation.SandboxID, observation.PodUID
		return c.putStatus(ctx, object, status)
	}
	if observation.Ready || len(observation.VMPIDs) != 0 {
		return nil
	}
	if status.DispatchCommittedAt != nil && status.RuntimeSandboxID == "" {
		if !status.CleanupUnverified {
			status.CleanupUnverified = true
			return c.putStatus(ctx, object, status)
		}
		return nil
	}
	status.CleanupUnverified = false
	status.CleanupComplete = true
	return c.putStatus(ctx, object, status)
}

func owned(object *unstructured.Unstructured, pod *corev1.Pod) bool {
	return slices.ContainsFunc(pod.OwnerReferences, func(owner metav1.OwnerReference) bool {
		return owner.UID == object.GetUID() && owner.Kind == "Execution" && owner.APIVersion == "foundation.sandbox.p5.dev/v1alpha1" && owner.Controller != nil && *owner.Controller
	})
}

func terminal(phase string) bool {
	return slices.Contains([]string{"Succeeded", "Failed", "Cancelled", "DeadlineExceeded", "UnknownOutcome", "Rejected"}, phase)
}

func (c *Controller) putStatus(ctx context.Context, object *unstructured.Unstructured, status Status) error {
	encoded, err := json.Marshal(status)
	if err != nil {
		return err
	}
	var value map[string]any
	if err := json.Unmarshal(encoded, &value); err != nil {
		return err
	}
	previous, _, _ := unstructured.NestedString(object.Object, "status", "phase")
	object.Object["status"] = value
	updated, err := c.objects.UpdateStatus(ctx, object, metav1.UpdateOptions{})
	if err == nil {
		*object = *updated
	}
	if err == nil && previous != status.Phase {
		log.Printf("execution=%s attempt=%s phase=%s reason=%s child=%s uid=%s", object.GetName(), status.AttemptID, status.Phase, status.Reason, status.ChildName, status.ChildUID)
	}
	return err
}

func (c *Controller) removeFinalizer(ctx context.Context, object *unstructured.Unstructured) error {
	if !slices.Contains(object.GetFinalizers(), finalizer) {
		return nil
	}
	object.SetFinalizers(slices.DeleteFunc(object.GetFinalizers(), func(value string) bool { return value == finalizer }))
	_, err := c.objects.Update(ctx, object, metav1.UpdateOptions{})
	return err
}

func (c *Controller) crash(object *unstructured.Unstructured, point string) {
	if c.faultName == object.GetName() && c.fault == point {
		log.Printf("injected crash execution=%s point=%s", object.GetName(), point)
		os.Exit(70)
	}
}

func decode(value any, destination any) error {
	encoded, err := json.Marshal(value)
	if err != nil {
		return err
	}
	return json.Unmarshal(encoded, destination)
}

func observe(ctx context.Context, namespace, podName, podUID, knownID string) (Observation, error) {
	var sandboxes struct {
		Items []struct {
			ID       string                                `json:"id"`
			State    string                                `json:"state"`
			Metadata struct{ Name, Namespace, UID string } `json:"metadata"`
		} `json:"items"`
	}
	output, err := exec.CommandContext(ctx, "docker", "exec", node, "crictl", "pods", "-o", "json").Output()
	if err != nil {
		return Observation{}, fmt.Errorf("CRI observation: %w", err)
	}
	if err := json.Unmarshal(output, &sandboxes); err != nil {
		return Observation{}, err
	}
	observation := Observation{SandboxID: knownID, PodUID: podUID, VMPIDs: []int{}}
	ids := []string{}
	if knownID != "" {
		ids = append(ids, knownID)
	}
	for _, sandbox := range sandboxes.Items {
		if sandbox.Metadata.Namespace == namespace && sandbox.Metadata.Name == podName && (podUID == "" || sandbox.Metadata.UID == podUID) {
			ids = append(ids, sandbox.ID)
			if observation.SandboxID == "" || sandbox.State == "SANDBOX_READY" {
				observation.SandboxID, observation.PodUID = sandbox.ID, sandbox.Metadata.UID
			}
			observation.Ready = observation.Ready || sandbox.State == "SANDBOX_READY"
		}
	}
	if observation.SandboxID == "" {
		return observation, nil
	}
	processes, err := exec.CommandContext(ctx, "docker", "exec", node, "ps", "-eo", "pid,args").Output()
	if err != nil {
		return Observation{}, err
	}
	for line := range strings.SplitSeq(string(processes), "\n") {
		if strings.Contains(line, "qemu-system") && slices.ContainsFunc(ids, func(id string) bool { return strings.Contains(line, id) }) {
			fields := strings.Fields(line)
			pid, err := strconv.Atoi(fields[0])
			if err != nil {
				return Observation{}, err
			}
			observation.VMPIDs = append(observation.VMPIDs, pid)
		}
	}
	return observation, nil
}
