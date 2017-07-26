# Copyright 2017 The Bazel Authors. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the Lice

"""Bazel rules for creating macOS applications and bundles."""

load(
    "@build_bazel_rules_apple//apple/bundling:binary_support.bzl",
    "binary_support",
)
load(
    "@build_bazel_rules_apple//apple/bundling:macos_command_line_support.bzl",
    "macos_command_line_infoplist",
    "macos_command_line_support",
)
load(
    "@build_bazel_rules_apple//apple/bundling:swift_support.bzl",
    "swift_runtime_linkopts",
)

# Alias the internal rules when we load them. This lets the rules keep their
# original name in queries and logs since they collide with the wrapper macros.
load(
    "@build_bazel_rules_apple//apple/bundling:macos_rules.bzl",
    _macos_application="macos_application",
    _macos_command_line_application="macos_command_line_application",
    _macos_extension="macos_extension",
)


def _create_swift_runtime_linkopts_target(name, deps, is_static):
  """Creates a build target to propagate Swift runtime linker flags.

  Args:
    name: The name of the base target.
    deps: The list of dependencies of the base target.
    is_static: True to use the static Swift runtime, or False to use the
        dynamic Swift runtime.
  Returns:
    A build label that can be added to the deps of the binary target.
  """
  swift_runtime_linkopts_name = name + ".swift_runtime_linkopts"
  swift_runtime_linkopts(
      name = swift_runtime_linkopts_name,
      is_static = is_static,
      deps = deps,
  )
  return ":" + swift_runtime_linkopts_name


def macos_application(name, **kwargs):
  """Packages a macOS application.

  The named target produced by this macro is a ZIP file. This macro also creates
  a target named "{name}.apple_binary" that represents the linked binary
  executable inside the application bundle.

  Args:
    name: The name of the target.
    app_icons: Files that comprise the app icons for the application. Each file
        must have a containing directory named "*.xcassets/*.appiconset" and
        there may be only one such .appiconset directory in the list.
    bundle_id: The bundle ID (reverse-DNS path followed by app name) of the
        application. Required.
    entitlements: The entitlements file required for this application. If
        absent, the default entitlements from the provisioning profile will be
        used. The following variables are substituted: $(CFBundleIdentifier)
        with the bundle ID and $(AppIdentifierPrefix) with the value of the
        ApplicationIdentifierPrefix key from this target's provisioning
        profile (or the default provisioning profile, if none is specified).
    extensions: A list of extensions to include in the final application.
    infoplists: A list of plist files that will be merged to form the
        Info.plist that represents the application.
    ipa_post_processor: A tool that edits this target's archive output
        after it is assembled but before it is (optionally) signed. The tool is
        invoked with a single positional argument that represents the path to a
        directory containing the unzipped contents of the archive. The only
        entry in this directory will be the Payload root directory of the
        archive. Any changes made by the tool must be made in this directory,
        and the tool's execution must be hermetic given these inputs to ensure
        that the result can be safely cached.
    linkopts: A list of strings representing extra flags that the underlying
        apple_binary target should pass to the linker.
    provisioning_profile: The provisioning profile (.provisionprofile file) to
        use when bundling the application.
    strings: A list of files that are plists of strings, often localizable.
        These files are converted to binary plists (if they are not already)
        and placed in the bundle root of the final package. If this file's
        immediate containing directory is named *.lproj, it will be placed
        under a directory of that name in the final bundle. This allows for
        localizable strings.
    deps: A list of dependencies, such as libraries, that are passed into the
        apple_binary rule. Any resources, such as asset catalogs, that are
        defined by these targets will also be transitively included in the
        final application.
  """
  binary_args = dict(kwargs)

  # TODO(b/62481675): Move these linkopts to CROSSTOOL features.
  linkopts = binary_args.get("linkopts", [])
  linkopts += ["-rpath", "@executable_path/../Frameworks"]
  binary_args["linkopts"] = linkopts

  original_deps = binary_args.pop("deps")
  binary_deps = list(original_deps)

  # Propagate the linker flags that dynamically link the Swift runtime.
  binary_deps.append(
      _create_swift_runtime_linkopts_target(name, original_deps, False))

  bundling_args = binary_support.create_binary(
      name,
      str(apple_common.platform_type.macos),
      deps=binary_deps,
      features=["link_cocoa"],
      **binary_args)

  _macos_application(
      name = name,
      **bundling_args
  )


def macos_command_line_application(name, **kwargs):
  """Builds a macOS command line application.

  A command line application is a standalone binary file, rather than a `.app`
  bundle like those produced by `macos_application`. Unlike a plain
  `apple_binary` target, however, this rule supports versioning and embedding an
  `Info.plist` into the binary and allows the binary to be code-signed.

  Args:
    name: The name of the target.
    bundle_id: The bundle ID (reverse-DNS path followed by app name) of the
        extension. Optional.
    infoplists: A list of plist files that will be merged and embedded in the
        binary.
    linkopts: A list of strings representing extra flags that should be passed
        to the linker.
    minimum_os_version: An optional string indicating the minimum macOS version
        supported by the target, represented as a dotted version number (for
        example, `"10.11"`). If this attribute is omitted, then the value
        specified by the flag `--macos_minimum_os` will be used instead.
    deps: A list of dependencies, such as libraries, that are linked into the
        final binary. Any resources found in those dependencies are
        ignored.
  """
  # Xcode will happily apply entitlements during code signing for a command line
  # tool even though it doesn't have a Capabilities tab in the project settings.
  # Until there's official support for it, we'll fail if we see those attributes
  # (which are added to the rule because of the code_signing_attributes usage in
  # the rule definition).
  if "entitlements" in kwargs or "provisioning_profile" in kwargs:
    fail("macos_command_line_application does not support entitlements or " +
         "provisioning profiles at this time")

  binary_args = dict(kwargs)

  original_deps = binary_args.pop("deps")
  binary_deps = list(original_deps)

  # If any of the Info.plist-affecting attributes is provided, create a merged
  # Info.plist target. This target also propagates an objc provider that
  # contains the linkopts necessary to add the Info.plist to the binary, so it
  # must become a dependency of the binary as well.
  bundle_id = binary_args.get("bundle_id")
  infoplists = binary_args.get("infoplists")
  version = binary_args.get("version")

  if bundle_id or infoplists or version:
    merged_infoplist_name = name + ".merged_infoplist"
    merged_infoplist_lib_name = merged_infoplist_name + "_lib"

    macos_command_line_infoplist(
        name = merged_infoplist_name,
        bundle_id = bundle_id,
        infoplists = infoplists,
        minimum_os_version = binary_args.get("minimum_os_version"),
        version = version,
    )
    native.objc_library(
        name = merged_infoplist_lib_name,
        srcs = [macos_command_line_support.infoplist_source_label(
            merged_infoplist_name)],
    )
    binary_deps.extend([
        ":" + merged_infoplist_name,
        ":" + merged_infoplist_lib_name,
    ])

  # Propagate the linker flags that statically link the Swift runtime.
  binary_deps.append(
      _create_swift_runtime_linkopts_target(name, original_deps, True))

  # Create the unsigned binary, then run the command line application rule that
  # signs it.
  cmd_line_app_args = binary_support.create_binary(
      name,
      str(apple_common.platform_type.macos),
      deps=binary_deps,
      **binary_args)
  cmd_line_app_args.pop("deps")

  _macos_command_line_application(
      name = name,
      **cmd_line_app_args
  )


def macos_extension(name, **kwargs):
  """Packages a macOS extension.

  The named target produced by this macro is a ZIP file. This macro also
  creates a target named "{name}.apple_binary" that represents the linked
  binary executable inside the extension bundle.

  Args:
    name: The name of the target.
    app_icons: Files that comprise the app icons for the extension. Each file
        must have a containing directory named "*.xcassets/*.appiconset" and
        there may be only one such .appiconset directory in the list.
    bundle_id: The bundle ID (reverse-DNS path followed by app name) of the
        extension. Required.
    entitlements: The entitlements file required for this application. If
        absent, the default entitlements from the provisioning profile will be
        used. The following variables are substituted: $(CFBundleIdentifier)
        with the bundle ID and $(AppIdentifierPrefix) with the value of the
        ApplicationIdentifierPrefix key from this target's provisioning
        profile (or the default provisioning profile, if none is specified).
    infoplists: A list of plist files that will be merged to form the
        Info.plist that represents the extension.
    ipa_post_processor: A tool that edits this target's archive output
        after it is assembled but before it is (optionally) signed. The tool is
        invoked with a single positional argument that represents the path to a
        directory containing the unzipped contents of the archive. The only
        entry in this directory will be the .appex directory for the extension.
        Any changes made by the tool must be made in this directory, and the
        tool's execution must be hermetic given these inputs to ensure that the
        result can be safely cached.
    linkopts: A list of strings representing extra flags that the underlying
        apple_binary target should pass to the linker.
    provisioning_profile: The provisioning profile (.provisionprofile file) to
        use when bundling the application.
    strings: A list of files that are plists of strings, often localizable.
        These files are converted to binary plists (if they are not already)
        and placed in the bundle root of the final package. If this file's
        immediate containing directory is named *.lproj, it will be placed
        under a directory of that name in the final bundle. This allows for
        localizable strings.
    deps: A list of dependencies, such as libraries, that are passed into the
        apple_binary rule. Any resources, such as asset catalogs, that are
        defined by these targets will also be transitively included in the
        final extension.
  """
  binary_args = dict(kwargs)

  # Add extension-specific linker options.
  # TODO(b/62481675): Move these linkopts to CROSSTOOL features.
  linkopts = binary_args.get("linkopts", [])
  linkopts += [
      "-e", "_NSExtensionMain",
      "-rpath", "@executable_path/../Frameworks",
      "-rpath", "@executable_path/../../../../Frameworks",
  ]
  binary_args["linkopts"] = linkopts

  original_deps = binary_args.pop("deps")
  binary_deps = list(original_deps)

  # Propagate the linker flags that dynamically link the Swift runtime.
  binary_deps.append(
      _create_swift_runtime_linkopts_target(name, original_deps, False))

  bundling_args = binary_support.create_binary(
      name,
      str(apple_common.platform_type.macos),
      deps=binary_deps,
      extension_safe=True,
      features=["link_cocoa"],
      **binary_args)

  _macos_extension(
      name = name,
      **bundling_args
  )