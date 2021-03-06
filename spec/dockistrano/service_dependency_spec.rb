require 'spec_helper'

describe Dockistrano::ServiceDependency do

  subject { described_class.new(service, "postgresql", { database: "application_development" }) }
  let(:service) { double(tag: "develop", registry: "my.registry.net") }
  let(:service_dependency) { double }

  context ".factory" do
    it "creates a new service based on the name" do
      expect(described_class).to receive(:new).and_return(service_dependency)
      expect(service_dependency).to receive(:initialized_backing_service).and_return(service)
      expect(described_class.factory(service, "redis", { foo: "bar" })).to eq(service)
    end

    it "creates a new service based on the name" do
      expect(described_class).to receive(:new).and_return(service_dependency)
      expect(service_dependency).to receive(:backing_service).and_return(service)
      expect(described_class.factory(service, "redis", { foo: "bar" }, false)).to eq(service)
    end
  end

  context "#backing_service" do
    it "backing service has registry of the service" do
      expect(subject.backing_service.registry).to eq("my.registry.net")
    end

    it "backing service has the name of the dependency" do
      expect(subject.backing_service.image_name).to eq("postgresql")
    end

    it "backing service has the tag of the service" do
      expect(subject.backing_service.tag).to eq("develop")
    end
  end

  context "#initialized_backing_service" do
    before do
      allow(subject).to receive(:load_config).and_return({ "default" => {} })
      allow(subject).to receive(:tag_with_fallback).and_return("develop")
    end

    it "backing service has backing service environment variables from configuration" do
      expect(subject.initialized_backing_service.backing_service_env).to eq({ database: "application_development" })
    end

    it "sets the tag with a fallback" do
      expect(subject).to receive(:tag_with_fallback).with("develop").and_return("latest")
      expect(subject.initialized_backing_service.tag).to eq("latest")
    end

    it "loads the configuration" do
      expect(subject).to receive(:load_config).and_return({ "default" => { "test_command" => "foobar" }})
      expect(subject.initialized_backing_service.test_command).to eq("foobar")
    end
  end

  context "#load_config" do
    it "uses the cache when available" do
      configuration = double
      allow(subject).to receive(:load_from_cache).and_return(configuration)
      expect(subject.load_config).to eq(configuration)
    end

    it "loads configuration from the image when no cache is available" do
      configuration = double
      allow(subject).to receive(:load_from_cache).and_return(nil)
      allow(subject).to receive(:load_from_image).and_return(configuration)
      expect(subject.load_config).to eq(configuration)
    end
  end

  context "#load_from_cache" do
    let(:backing_service) { double(image_id: "123456789") }

    before do
      allow(subject).to receive(:backing_service).and_return(backing_service)
    end

    it "returns nil when no cache is found" do
      expect(File).to receive(:exists?).with("tmp/configuration_cache/123456789").and_return(false)
      expect(subject.load_from_cache).to eq(nil)
    end

    it "returns the configuration when a cache is found" do
      expect(File).to receive(:exists?).with("tmp/configuration_cache/123456789").and_return(true)
      expect(YAML).to receive(:load_file).with("tmp/configuration_cache/123456789").and_return({ "default" => { "image_name" => "foobar "}})
      expect(subject.load_from_cache).to eq({ "default" => { "image_name" => "foobar "}})
    end
  end

  context "#load_from_image" do
    let(:backing_service) { double(full_image_name: "registry/application:develop", image_id: "123456789") }
    let(:configuration) { double }

    before do
      allow(subject).to receive(:backing_service).and_return(backing_service)
    end

    it "reads the configuration from the image and caches the configuration" do
      expect(Dockistrano::Docker).to receive(:run).with(backing_service.full_image_name, command: "cat /dockistrano.yml", rm: true).and_return(raw_config = "---\ndefault:\n\tconfiguration: value")

      expect(FileUtils).to receive(:mkdir_p).with("tmp/configuration_cache")
      expect(File).to receive(:open).with("tmp/configuration_cache/#{backing_service.image_id}", "w+").and_return(file = double)
      expect(file).to receive(:write).with(raw_config)
      expect(file).to receive(:close)

      expect(YAML).to receive(:load).with(raw_config).and_return(configuration)

      expect(subject.load_from_image).to eq(configuration)
    end

    it "raises an error when host directories are missing" do
      expect(Dockistrano::Docker).to receive(:run).with(backing_service.full_image_name, command: "cat /dockistrano.yml", rm: true).and_return("No such file or directory: failed to mount")
      expect { subject.load_from_image }.to raise_error(Dockistrano::ServiceDependency::HostDirectoriesMissing)
    end

    it "raises an error when the configuration is not found" do
      expect(Dockistrano::Docker).to receive(:run).with(backing_service.full_image_name, command: "cat /dockistrano.yml", rm: true).and_return("No such file or directory: dockistrano.yml")
      expect { subject.load_from_image }.to raise_error(Dockistrano::ServiceDependency::ContainerConfigurationMissing)
    end

    it "raises an error when the configuration is empty" do
      expect(Dockistrano::Docker).to receive(:run).with(backing_service.full_image_name, command: "cat /dockistrano.yml", rm: true).and_return("")
      expect { subject.load_from_image }.to raise_error(Dockistrano::ServiceDependency::ContainerConfigurationMissing)
    end
  end

  context "#tag_with_fallback" do
    let(:backing_service) { double(registry: "registry", image_name: "postgresql") }

    before do
      allow(subject).to receive(:backing_service).and_return(backing_service)
    end

    it "returns the given tag when the tag is available" do
      expect(Dockistrano::Docker).to receive(:tags_for_image).and_return(["feature-branch", "develop", "master", "latest"])
      expect(subject.tag_with_fallback("feature-branch")).to eq("feature-branch")
    end

    it "returns develop when the specific tag is not available" do
      expect(Dockistrano::Docker).to receive(:tags_for_image).and_return(["develop", "master", "latest"])
      expect(subject.tag_with_fallback("feature-branch")).to eq("develop")
    end

    it "returns master when develop is not available" do
      expect(Dockistrano::Docker).to receive(:tags_for_image).and_return(["master", "latest"])
      expect(subject.tag_with_fallback("feature-branch")).to eq("master")
    end

    it "returns latest when master is not available" do
      expect(Dockistrano::Docker).to receive(:tags_for_image).and_return(["latest"])
      expect(subject.tag_with_fallback("feature-branch")).to eq("latest")
    end

    it "raises an error when not appropriate tag is found" do
      expect(Dockistrano::Docker).to receive(:tags_for_image).and_return(["another-feature-branch"])
      expect { subject.tag_with_fallback("feature-branch") }.to raise_error(Dockistrano::ServiceDependency::NoTagFoundForImage)
    end
  end

end
