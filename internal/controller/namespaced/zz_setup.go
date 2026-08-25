// SPDX-FileCopyrightText: 2024 The Crossplane Authors <https://crossplane.io>
//
// SPDX-License-Identifier: Apache-2.0

package controller

import (
	ctrl "sigs.k8s.io/controller-runtime"

	"github.com/crossplane/upjet/v2/pkg/controller"

	providerconfig "github.com/brezzy1337/provider-upjet-railway/internal/controller/namespaced/providerconfig"
	customdomain "github.com/brezzy1337/provider-upjet-railway/internal/controller/namespaced/railway/customdomain"
	environment "github.com/brezzy1337/provider-upjet-railway/internal/controller/namespaced/railway/environment"
	project "github.com/brezzy1337/provider-upjet-railway/internal/controller/namespaced/railway/project"
	service "github.com/brezzy1337/provider-upjet-railway/internal/controller/namespaced/railway/service"
	servicedomain "github.com/brezzy1337/provider-upjet-railway/internal/controller/namespaced/railway/servicedomain"
	sharedvariable "github.com/brezzy1337/provider-upjet-railway/internal/controller/namespaced/railway/sharedvariable"
	tcpproxy "github.com/brezzy1337/provider-upjet-railway/internal/controller/namespaced/railway/tcpproxy"
	variable "github.com/brezzy1337/provider-upjet-railway/internal/controller/namespaced/railway/variable"
	variablecollection "github.com/brezzy1337/provider-upjet-railway/internal/controller/namespaced/railway/variablecollection"
)

// Setup creates all controllers with the supplied logger and adds them to
// the supplied manager.
func Setup(mgr ctrl.Manager, o controller.Options) error {
	for _, setup := range []func(ctrl.Manager, controller.Options) error{
		providerconfig.Setup,
		customdomain.Setup,
		environment.Setup,
		project.Setup,
		service.Setup,
		servicedomain.Setup,
		sharedvariable.Setup,
		tcpproxy.Setup,
		variable.Setup,
		variablecollection.Setup,
	} {
		if err := setup(mgr, o); err != nil {
			return err
		}
	}
	return nil
}

// SetupGated creates all controllers with the supplied logger and adds them to
// the supplied manager gated.
func SetupGated(mgr ctrl.Manager, o controller.Options) error {
	for _, setup := range []func(ctrl.Manager, controller.Options) error{
		providerconfig.SetupGated,
		customdomain.SetupGated,
		environment.SetupGated,
		project.SetupGated,
		service.SetupGated,
		servicedomain.SetupGated,
		sharedvariable.SetupGated,
		tcpproxy.SetupGated,
		variable.SetupGated,
		variablecollection.SetupGated,
	} {
		if err := setup(mgr, o); err != nil {
			return err
		}
	}
	return nil
}

// SetupWebhookWithManager registers conversion webhooks for all resource kinds in the group.
func SetupWebhookWithManager(mgr ctrl.Manager) error {
	for _, setup := range []func(ctrl.Manager) error{
		providerconfig.SetupWebhookWithManager,
		customdomain.SetupWebhookWithManager,
		environment.SetupWebhookWithManager,
		project.SetupWebhookWithManager,
		service.SetupWebhookWithManager,
		servicedomain.SetupWebhookWithManager,
		sharedvariable.SetupWebhookWithManager,
		tcpproxy.SetupWebhookWithManager,
		variable.SetupWebhookWithManager,
		variablecollection.SetupWebhookWithManager,
	} {
		if err := setup(mgr); err != nil {
			return err
		}
	}
	return nil
}
