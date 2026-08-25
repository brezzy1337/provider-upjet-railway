package config

import (
	"github.com/crossplane/upjet/v2/pkg/config"
)

// ExternalNameConfigs contains all external name configurations for this
// provider.
//
// Every Railway resource gets a server-generated identifier, so the external
// name is taken from the provider (`IdentifierFromProvider`). The upstream
// Terraform provider's `terraform import` IDs are noted per resource because
// several are colon-joined composites rather than the bare `id`; importing
// pre-existing resources will need per-resource GetIDFn handling later.
var ExternalNameConfigs = map[string]config.ExternalName{
	// import: <project_id>
	"railway_project": config.IdentifierFromProvider,
	// import: <project_id>:<name>
	"railway_environment": config.IdentifierFromProvider,
	// import: <service_id>
	"railway_service": config.IdentifierFromProvider,
	// import: <service_id>:<environment_name>:<name>
	"railway_variable": config.IdentifierFromProvider,
	// import: <service_id>:<environment_name>:<name1>:<name2>:...
	"railway_variable_collection": config.IdentifierFromProvider,
	// import: <project_id>:<environment_name>:<name>
	"railway_shared_variable": config.IdentifierFromProvider,
	// import: <service_id>:<environment_name>:<domain>
	"railway_custom_domain": config.IdentifierFromProvider,
	// import: <service_id>:<environment_name>:<domain>
	"railway_service_domain": config.IdentifierFromProvider,
	// import: <service_id>:<environment_id>:<tcp_proxy_id>
	"railway_tcp_proxy": config.IdentifierFromProvider,
}

// ExternalNameConfigurations applies all external name configs listed in the
// table ExternalNameConfigs and sets the version of those resources to v1beta1
// assuming they will be tested.
func ExternalNameConfigurations() config.ResourceOption {
	return func(r *config.Resource) {
		if e, ok := ExternalNameConfigs[r.Name]; ok {
			r.ExternalName = e
		}
	}
}

// ExternalNameConfigured returns the list of all resources whose external name
// is configured manually.
func ExternalNameConfigured() []string {
	l := make([]string, len(ExternalNameConfigs))
	i := 0
	for name := range ExternalNameConfigs {
		// $ is added to match the exact string since the format is regex.
		l[i] = name + "$"
		i++
	}
	return l
}
