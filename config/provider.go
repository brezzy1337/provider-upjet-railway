package config

import (
	// Note(turkenh): we are importing this to embed provider schema document
	_ "embed"
	"strings"

	ujconfig "github.com/crossplane/upjet/v2/pkg/config"
	"github.com/crossplane/upjet/v2/pkg/types/name"

	"github.com/brezzy1337/provider-upjet-railway/config/railway"
)

const (
	resourcePrefix = "railway"
	modulePath     = "github.com/brezzy1337/provider-upjet-railway"
)

//go:embed schema.json
var providerSchema string

//go:embed provider-metadata.yaml
var providerMetadata string

// groupKindOverrides puts every resource in the root API group
// (railway.crossplane.io) with a Kind that is the full resource name in
// CamelCase. Upjet's default would split on the first word of the name and
// produce groups like `custom.railway.crossplane.io` with Kind `Domain`.
func groupKindOverrides() ujconfig.ResourceOption {
	return func(r *ujconfig.Resource) {
		r.ShortGroup = ""
		r.Kind = name.NewFromSnake(strings.TrimPrefix(r.Name, resourcePrefix+"_")).Camel
	}
}

// GetProvider returns provider configuration
func GetProvider() *ujconfig.Provider {
	pc := ujconfig.NewProvider([]byte(providerSchema), resourcePrefix, modulePath, []byte(providerMetadata),
		ujconfig.WithRootGroup("railway.crossplane.io"),
		ujconfig.WithIncludeList(ExternalNameConfigured()),
		ujconfig.WithFeaturesPackage("internal/features"),
		ujconfig.WithDefaultResourceOptions(
			groupKindOverrides(),
			ExternalNameConfigurations(),
		))

	for _, configure := range []func(provider *ujconfig.Provider){
		railway.Configure,
	} {
		configure(pc)
	}

	pc.ConfigureResources()
	return pc
}

// GetProviderNamespaced returns the namespaced provider configuration
func GetProviderNamespaced() *ujconfig.Provider {
	pc := ujconfig.NewProvider([]byte(providerSchema), resourcePrefix, modulePath, []byte(providerMetadata),
		ujconfig.WithRootGroup("railway.m.crossplane.io"),
		ujconfig.WithIncludeList(ExternalNameConfigured()),
		ujconfig.WithFeaturesPackage("internal/features"),
		ujconfig.WithDefaultResourceOptions(
			groupKindOverrides(),
			ExternalNameConfigurations(),
		),
		ujconfig.WithExampleManifestConfiguration(ujconfig.ExampleManifestConfiguration{
			ManagedResourceNamespace: "crossplane-system",
		}))

	for _, configure := range []func(provider *ujconfig.Provider){
		railway.Configure,
	} {
		configure(pc)
	}

	pc.ConfigureResources()
	return pc
}
