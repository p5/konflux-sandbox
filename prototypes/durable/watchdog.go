package main

import (
	"context"
	"encoding/json"
	"log"
	"os"
	"time"

	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// The watchdog never allocates a child or writes execution status.
func (c *Controller) watch(ctx context.Context) {
	for ctx.Err() == nil {
		objects, err := c.objects.List(ctx, metav1.ListOptions{})
		if err != nil {
			log.Printf("watchdog list: %v", err)
		} else {
			for _, object := range objects.Items {
				var spec Spec
				var status Status
				if decode(object.Object["spec"], &spec) != nil || decode(object.Object["status"], &status) != nil {
					continue
				}
				reason := ""
				if spec.Cancel || object.GetDeletionTimestamp() != nil {
					reason = "Cancellation"
				}
				if time.Now().After(spec.Deadline) {
					reason = "AbsoluteDeadline"
				}
				if reason == "" {
					continue
				}
				name := status.ChildName
				if name == "" {
					name = "exec-" + string(object.GetUID()) + "-" + spec.AttemptID
				}
				pod, err := c.kube.CoreV1().Pods(c.namespace).Get(ctx, name, metav1.GetOptions{})
				if apierrors.IsNotFound(err) {
					continue
				}
				if err != nil {
					log.Printf("watchdog child: %v", err)
					continue
				}
				if !owned(&object, pod) || (status.ChildUID != "" && status.ChildUID != string(pod.UID)) {
					log.Printf("watchdog rejected foreign child execution=%s", object.GetName())
					continue
				}
				if pod.DeletionTimestamp != nil {
					continue
				}
				err = c.kube.CoreV1().Pods(c.namespace).Delete(ctx, name, metav1.DeleteOptions{GracePeriodSeconds: new(int64(1)), Preconditions: &metav1.Preconditions{UID: new(pod.UID)}})
				if err != nil {
					log.Printf("watchdog delete: %v", err)
					continue
				}
				_ = json.NewEncoder(os.Stdout).Encode(struct {
					At        time.Time `json:"at"`
					Execution string    `json:"execution"`
					PodUID    string    `json:"podUID"`
					Reason    string    `json:"reason"`
				}{time.Now().UTC(), object.GetName(), string(pod.UID), reason})
			}
		}
		select {
		case <-ctx.Done():
			return
		case <-time.After(250 * time.Millisecond):
		}
	}
}
