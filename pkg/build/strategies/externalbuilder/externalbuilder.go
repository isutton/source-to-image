package externalbuilder

import (
	"github.com/openshift/source-to-image/pkg/api"
	"github.com/openshift/source-to-image/pkg/build/strategies/dockerfile"
	"github.com/openshift/source-to-image/pkg/util/fs"
)

type ExternalBuilder struct {
	buildCommand string
}

func NewOsExecBuilder(config *api.Config) (*ExternalBuilder, error) {
	return &ExternalBuilder{
		buildCommand: config.WithBuilder,
	}, nil
}

func (builder ExternalBuilder) Build(config *api.Config) (*api.Result, error) {
	_, err := builder.buildDockerfile(config)
	if err != nil {
		return nil, err
	}

	return builder.build(config)
}

func (builder ExternalBuilder) buildDockerfile(config *api.Config) (*api.Result, error) {
	fileSystem := fs.NewFileSystem()

	dockerfileBuilder, err := dockerfile.New(config, fileSystem)
	if err != nil {
		return nil, err
	}

	dockerfileBuilderResult, err := dockerfileBuilder.Build(config)
	if err != nil {
		return nil, err
	}

	return dockerfileBuilderResult, nil
}

func (ExternalBuilder) build(config *api.Config) (*api.Result, error) {
	panic("implement me!")
}
