package main

import (
	"maps"
	"math"
	"slices"
	"time"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
)

func childPod(object *unstructured.Unstructured, spec Spec, status Status) *corev1.Pod {
	seconds := max(int64(1), int64(math.Ceil(time.Until(spec.Deadline).Seconds())))
	environment := []corev1.EnvVar{}
	for _, key := range slices.Sorted(maps.Keys(spec.Env)) {
		environment = append(environment, corev1.EnvVar{Name: key, Value: spec.Env[key]})
	}
	return &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{
			Name:      status.ChildName,
			Namespace: object.GetNamespace(),
			Labels: map[string]string{
				"foundation.sandbox.p5.dev/execution": object.GetName(),
				"foundation.sandbox.p5.dev/attempt":   spec.AttemptID,
			},
			Annotations: map[string]string{
				"foundation.sandbox.p5.dev/owner":   spec.OwnerID,
				"foundation.sandbox.p5.dev/source":  spec.SourceDigest,
				"foundation.sandbox.p5.dev/profile": spec.ProfileDigest,
			},
			OwnerReferences: []metav1.OwnerReference{{
				APIVersion: "foundation.sandbox.p5.dev/v1alpha1", Kind: "Execution",
				Name: object.GetName(), UID: object.GetUID(), Controller: new(true), BlockOwnerDeletion: new(true),
			}},
		},
		Spec: corev1.PodSpec{
			ServiceAccountName:            "durable-guest",
			RuntimeClassName:              new("kata-prototype"),
			AutomountServiceAccountToken:  new(false),
			RestartPolicy:                 corev1.RestartPolicyNever,
			ActiveDeadlineSeconds:         new(seconds),
			TerminationGracePeriodSeconds: new(int64(1)),
			SecurityContext:               &corev1.PodSecurityContext{RunAsUser: new(int64(1000)), RunAsGroup: new(int64(1000)), FSGroup: new(int64(1000))},
			Containers: []corev1.Container{{
				Name: "guest", Image: spec.Image, ImagePullPolicy: corev1.PullNever, Command: spec.Command, Env: environment,
				Resources: corev1.ResourceRequirements{
					Requests: corev1.ResourceList{corev1.ResourceCPU: resource.MustParse("100m"), corev1.ResourceMemory: resource.MustParse("128Mi")},
					Limits:   corev1.ResourceList{corev1.ResourceCPU: resource.MustParse("1"), corev1.ResourceMemory: resource.MustParse("512Mi")},
				},
				SecurityContext: &corev1.SecurityContext{AllowPrivilegeEscalation: new(false), Capabilities: &corev1.Capabilities{Drop: []corev1.Capability{"ALL"}}},
			}},
		},
	}
}
