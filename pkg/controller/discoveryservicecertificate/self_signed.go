package discoveryservicecertificate

import (
	"context"
	"time"

	operatorv1alpha1 "github.com/3scale/marin3r/pkg/apis/operator/v1alpha1"
	"github.com/3scale/marin3r/pkg/util/pki"
	"github.com/operator-framework/operator-sdk/pkg/status"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"
)

func (r *ReconcileDiscoveryServiceCertificate) reconcileSelfSignedCertificate(ctx context.Context, dsc *operatorv1alpha1.DiscoveryServiceCertificate) error {

	// Fetch the certmanagerv1alpha2.Certificate instance
	secret := &corev1.Secret{}
	err := r.client.Get(context.TODO(),
		types.NamespacedName{
			Name:      dsc.Spec.SecretRef.Name,
			Namespace: dsc.Spec.SecretRef.Namespace,
		},
		secret)

	if err != nil {
		if errors.IsNotFound(err) {
			// Generate secret with a self signed certificate
			secret, err := genSelfSignedCertificateObject(dsc.Spec)
			if err != nil {
				return err
			}
			if err := controllerutil.SetControllerReference(dsc, secret, r.scheme); err != nil {
				return err
			}
			if err := r.client.Create(ctx, secret); err != nil {
				return err
			}
			r.logger.Info("Created self-signed certificate")
			return nil
		}
		return err
	}

	// Don't reconcile if renewal is disabled
	if dsc.Spec.CertificateRenewalConfig != nil && !dsc.Spec.CertificateRenewalConfig.Enabled {
		return nil
	}

	// Load the certificate
	cert, err := pki.LoadX509Certificate(secret.Data["tls.crt"])
	if err != nil {
		return err
	}

	// Check if certificate is invalid
	err = pki.Verify(cert, cert)
	if err != nil {
		r.logger.Error(err, "Invalid certificate detected")
	}

	// If certificate is invalid or has been marked for renewal, reissue it
	if err != nil || dsc.Status.Conditions.IsTrueFor(operatorv1alpha1.CertificateNeedsRenewalCondition) {
		new, err := genSelfSignedCertificateObject(dsc.Spec)
		if err != nil {
			return err
		}
		patch := client.MergeFrom(secret.DeepCopy())
		secret.Data = new.Data
		if err := r.client.Patch(ctx, secret, patch); err != nil {
			return err
		}
		r.logger.Info("Re-issued self-signed certificate")

		// Notify other controllers if notifications are configured
		// for this
		// TODO: look for a better way to do this. If we fail somewhere
		// before notifing the other controller, this won't be retried
		// and the condition will never be set
		if dsc.Spec.CertificateRenewalConfig != nil && dsc.Spec.CertificateRenewalConfig.Notify != nil {
			switch dsc.Spec.CertificateRenewalConfig.Notify.Kind {
			case operatorv1alpha1.DiscoveryServiceKind:
				ds := &operatorv1alpha1.DiscoveryService{}
				if err := r.client.Get(ctx, types.NamespacedName{
					Name:      dsc.Spec.CertificateRenewalConfig.Notify.Name,
					Namespace: dsc.Spec.CertificateRenewalConfig.Notify.Namespace},
					ds); err != nil {
					return err
				}

				if !ds.Status.Conditions.IsTrueFor(operatorv1alpha1.ServerRestartRequiredCondition) {
					patch := client.MergeFrom(ds.DeepCopy())
					ds.Status.Conditions.SetCondition(status.Condition{
						Type:    operatorv1alpha1.ServerRestartRequiredCondition,
						Reason:  "ServerCertificateReissued",
						Status:  corev1.ConditionTrue,
						Message: "Server certificate has been reissued",
					})
					if err := r.client.Status().Patch(ctx, ds, patch); err != nil {
						return err
					}
					r.logger.V(1).Info("Notified the DiscoveryService controller")
				}
			default:
				r.logger.Info("Notification for this Kind is not implemented")
			}
		}

	}

	if dsc.Status.Conditions.IsTrueFor(operatorv1alpha1.CertificateNeedsRenewalCondition) {
		// remove the condition
		patch := client.MergeFrom(dsc.DeepCopy())
		dsc.Status.Conditions.RemoveCondition(operatorv1alpha1.CertificateNeedsRenewalCondition)
		if err := r.client.Status().Patch(ctx, dsc, patch); err != nil {
			return err
		}
	}

	return nil
}

func genSelfSignedCertificateObject(cfg operatorv1alpha1.DiscoveryServiceCertificateSpec) (*corev1.Secret, error) {

	crt, key, err := pki.GenerateCertificate(
		nil,
		nil,
		cfg.CommonName,
		time.Duration(cfg.ValidFor)*time.Second,
		cfg.IsServerCertificate,
		cfg.IsCA,
		cfg.Hosts...,
	)
	if err != nil {
		return nil, err
	}
	secret := &corev1.Secret{
		ObjectMeta: metav1.ObjectMeta{
			Name:      cfg.SecretRef.Name,
			Namespace: cfg.SecretRef.Namespace,
		},
		Type: corev1.SecretTypeTLS,
		Data: map[string][]byte{"tls.crt": crt, "tls.key": key},
	}

	return secret, err
}