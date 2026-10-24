#!/usr/bin/env python3
"""Generate the small Xcode project deterministically, without third-party tools."""
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
objects = {}


def ident(name):
    return hashlib.sha256(name.encode()).hexdigest()[:24].upper()


def add(object_name, isa, **values):
    key = ident(object_name)
    objects[key] = {"isa": isa, **values}
    return key


def serialize(value, level=0):
    if isinstance(value, dict):
        return "{\n" + "".join("\t" * (level + 1) + json.dumps(k) + " = " + serialize(v, level + 1) + ";\n"
                              for k, v in value.items()) + "\t" * level + "}"
    if isinstance(value, list):
        return "(\n" + "".join("\t" * (level + 1) + serialize(v, level + 1) + ",\n" for v in value) + "\t" * level + ")"
    return json.dumps(str(value))


source_files = sorted((ROOT / "App").glob("*.swift"))
source_refs, source_builds = [], []
for path in source_files:
    relative = str(path.relative_to(ROOT))
    ref = add(relative, "PBXFileReference", lastKnownFileType="sourcecode.swift", path=relative, sourceTree="SOURCE_ROOT")
    source_refs.append(ref)
    source_builds.append(add("build:" + relative, "PBXBuildFile", fileRef=ref))
plist = add("plist", "PBXFileReference", lastKnownFileType="text.plist.xml", path="App/Info.plist", sourceTree="SOURCE_ROOT")
config = add("config", "PBXFileReference", lastKnownFileType="text.xcconfig", path="Config/Base.xcconfig", sourceTree="SOURCE_ROOT")
product = add("product", "PBXFileReference", explicitFileType="wrapper.application", path="MetaStudy.app", sourceTree="BUILT_PRODUCTS_DIR")
products = add("products", "PBXGroup", children=[product], name="Products", sourceTree="<group>")
group = add("root", "PBXGroup", children=source_refs + [plist, config, products], sourceTree="<group>")
sdk = add("sdk", "XCRemoteSwiftPackageReference", repositoryURL="https://github.com/facebook/meta-wearables-dat-ios",
          requirement={"kind": "exactVersion", "version": "1.0.1"})
core = add("core", "XCLocalSwiftPackageReference", relativePath=".")
package_products, frameworks = [], []
for name in ["MWDATCore", "MWDATCamera", "MWDATDisplay", "MetaStudyCore"]:
    dependency = add("package:" + name, "XCSwiftPackageProductDependency", package=core if name == "MetaStudyCore" else sdk,
                     productName=name)
    package_products.append(dependency)
    frameworks.append(add("framework:" + name, "PBXBuildFile", productRef=dependency))
sources = add("sources", "PBXSourcesBuildPhase", buildActionMask=2147483647, files=source_builds, runOnlyForDeploymentPostprocessing=0)
framework_phase = add("frameworks", "PBXFrameworksBuildPhase", buildActionMask=2147483647, files=frameworks, runOnlyForDeploymentPostprocessing=0)
resources = add("resources", "PBXResourcesBuildPhase", buildActionMask=2147483647, files=[], runOnlyForDeploymentPostprocessing=0)
project_configs, target_configs = [], []
for name in ["Debug", "Release"]:
    settings = {
        "SDKROOT": "iphoneos", "IPHONEOS_DEPLOYMENT_TARGET": "17.2", "SWIFT_VERSION": "5.0",
        "CLANG_ENABLE_MODULES": "YES", "CLANG_ENABLE_OBJC_ARC": "YES",
        "SWIFT_OPTIMIZATION_LEVEL": "-Onone" if name == "Debug" else "-O",
        "DEBUG_INFORMATION_FORMAT": "dwarf" if name == "Debug" else "dwarf-with-dsym",
    }
    if name == "Debug":
        settings["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] = "DEBUG $(inherited)"
        settings["ENABLE_TESTABILITY"] = "YES"
    project_configs.append(add("project:" + name, "XCBuildConfiguration", name=name, buildSettings=settings))
    target_settings = {
        "PRODUCT_NAME": "$(TARGET_NAME)", "INFOPLIST_FILE": "App/Info.plist",
        "GENERATE_INFOPLIST_FILE": "NO", "CODE_SIGN_STYLE": "Automatic",
        "TARGETED_DEVICE_FAMILY": "1", "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator",
        "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/Frameworks"],
        "SWIFT_EMIT_LOC_STRINGS": "YES", "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
    }
    target_configs.append(add("target:" + name, "XCBuildConfiguration", name=name, buildSettings=target_settings,
                              baseConfigurationReference=config))
project_list = add("project-configs", "XCConfigurationList", buildConfigurations=project_configs, defaultConfigurationIsVisible=0, defaultConfigurationName="Release")
target_list = add("target-configs", "XCConfigurationList", buildConfigurations=target_configs, defaultConfigurationIsVisible=0, defaultConfigurationName="Release")
target = add("target", "PBXNativeTarget", buildConfigurationList=target_list,
             buildPhases=[sources, framework_phase, resources], buildRules=[], dependencies=[],
             name="MetaStudy", packageProductDependencies=package_products,
             productName="MetaStudy", productReference=product, productType="com.apple.product-type.application")
project = add("project", "PBXProject", attributes={"BuildIndependentTargetsInParallel": "YES", "LastUpgradeCheck": "2660"},
              buildConfigurationList=project_list, compatibilityVersion="Xcode 14.0", developmentRegion="en",
              hasScannedForEncodings=0, knownRegions=["en", "Base"], mainGroup=group,
              packageReferences=[sdk, core], productRefGroup=products, projectDirPath="", projectRoot="", targets=[target])
document = {"archiveVersion": "1", "classes": {}, "objectVersion": "56", "objects": objects, "rootObject": project}
folder = ROOT / "MetaStudy.xcodeproj"
folder.mkdir(exist_ok=True)
(folder / "project.pbxproj").write_text("// !$*UTF8*$!\n" + serialize(document) + "\n")
scheme_folder = folder / "xcshareddata" / "xcschemes"
scheme_folder.mkdir(parents=True, exist_ok=True)
reference = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="MetaStudy.app" BlueprintName="MetaStudy" ReferencedContainer="container:MetaStudy.xcodeproj"/>'
(scheme_folder / "MetaStudy.xcscheme").write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2660" version="1.3">
  <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries>
    <BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{reference}</BuildActionEntry>
  </BuildActionEntries></BuildAction>
  <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{reference}</BuildableProductRunnable></LaunchAction>
  <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{reference}</BuildableProductRunnable></ProfileAction>
  <AnalyzeAction buildConfiguration="Debug"/>
  <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
''')
print(f"Generated MetaStudy.xcodeproj with {len(source_files)} app source files.")
