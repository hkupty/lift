# Lift

> raise to a higher position or level; to elevate.

Lift is a declarative build system for java, written in zig. Currently under development, very experimental.

## ⚠ Status

Inception/Development

## 📜 Sample

```toml
# optional lift.toml for mutli-project builds
[[projects]]
name = "myapp"
path = "apps/myapp/"
```

```toml
# apps/myapp/build.toml
[dependencies]
runner = "dependencies-v0"
data = [
  'org.slf4j:slf4j-api:jar:2.0.17'
]

[sources]
runner = "sources-v0"
data = [
  './src/main/java/'
]

[compile]
runner = "compile-v0"
dependsOn = ['dependencies', 'sources']

[compile.data]
targetVersion = 21
sourceVersion = 21

[testDependencies]
runner = "dependencies-v0"
data = [
  'org.junit.jupiter:junit-jupiter-engine:jar:6.0.0-M2'
]

[testSources]
runner = "sources-v0"
data = [
  './src/test/java/'
]

[test]
runner = "junit-runner-v0"
dependsOn = [
    "sources",
    "testSources",

    "dependencies",
    "testDependencies"
]

[build]
dependsOn = ['compile', 'test']

[jar]
runner = "jar-v0"
dependsOn = ['build']
```

```bash
# Running lift anywhere inside a git repository will work by named project
lift myapp:build

# Additionally, passing the path directly bypasses the need for `lift.toml`
lift ../apps/myapp:build
```


## 🎯 Goals

### 🍃 Simple

Lift aims to be simple to use and to understand.

The structure is generic and lean:

- `Project`: A complete module. For multi-module builds, each module is a `Project`. No top-level project is necessary;
- `Step`: A step is equivalent to a "build target", or, simply put, an action that needs to be executed in the build system.

#### How does only project and steps make a complete java build system?

Steps declare their dependencies to other steps and the composite project is a graph of all the steps and their dependencies.

Take a look at the example above.

The `jar` target depends on the `build` target, which in turn will depend on `compile` and `test`, each with their set of dependencies.

Some `Steps` have `data` associated, which can be either a list or a map, and can be seen as some configuration for the step to execute correctly.


### 🧩 Extensible

As you saw in the example above, each `Step` declares their own data, their runners and their dependencies. While Lift aims to provide a set of default runners (for the common cases), the steps can take any binary as a runner, in any language.

This also opens up the possibility to writing your own runners or community-based solutions.

Architecturally speaking, a runner is a program that Lift executes to fulfill a step. It takes JSON metadata from its dependencies and returns a JSON result describing its output.

Those json files must _not_ include the binary artifacts, if any, but should include the paths to such files.

### 🫂 CI-Friendly

One of the core goals is to _respect_ your CI resources. This means that it aims to leverage distributed caching to speed up runs and avoid re-processing unnecessary steps. Although the API is still not set, the intention is to use a merkle-tree-like structure to distribute artifacts and metadata, enabling fast runs.

### 🔢 Deterministic builds

Lift aims to ensure that two runs with the same inputs will produce the same output. Not only this is an important feature to have, it is a pre-requisite for the CI-Friendly goal.

### 🚢 Delivery focused

Lift should enable delivering things easily. It is a tool to aid in the release process and should not get in your way.

Another core goal is to enable seamless integration of technologies such as `jlink` or building containers from the build system,
so technology can evolve around lift while it is not a blocker for adoption or testing them.

## ❌ What Lift _isn't_

### Not a Maven/Gradle plugin system

Lift is a completely new and independent build system, built from scratch, with the intention of providing great developer experience.

### Not a general-purpose task runner like Make

Lift is not a Make/Just/Taskfile implementation. It is designed with building apps and systems in mind with clear task inter-dependencies and artifact deliverables. Although it is _possible_ to achieve similar results, using Lift for that purpose would be unnecessarily more complex that just using those tools instead.

### Not limited to Java forever (though JVM is the current focus)

As a small starting project, we need to start somewhere and trying to embrace everything is a recipe for disaster. Over time, more technologies could be supported, so growing from java to other JVM languages is a natural next step (one could imagine, assuming Lift is already fully implemented). It will, of course, depend on the project longevity and sustainability.

## ❔ Q&A

### Why another build system?

Maven and Gradle have been running for very long and, albeit successful, each have their own shortcomings, which opens up for innovation. Independently of adoption, the motivation for Lift is so I can unleash ideas and concepts I wanted to try out and things I wanted to learn. And we all know that the best way of learning is by doing.

### Why zig? Can't write good software in java?

There are two distinct answers for this question. First, because I wanted to. I wanted to learn zig and it feels like a good use-case for the language. Now, if that doesn't satisfy you, a more practical reason is so we don't have a bootstrap problem, where the build tool's support to new JVMs is limited by its own highest supported JVM version. Paradoxically, by writing a java build system in java - or in a jvm-based language - one is less likely to quickly support new java versions than if not using java.

### How can I help?

Lift is far from testing-material yet, but when things are better, surely some help on that area will be appreciated.
PRs and issues are always welcome. If you're _really_ excited by this idea and want it to happen, you can always fund my work so I can dedicate exclusive time to Lift.

### When will this be ready?

Hopefully some day. Depends on many things, including the amount of time I'm able to dedicate to it.
