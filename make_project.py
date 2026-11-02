"""Regenerate the dependency-free Xcode project. Python 3; no packages required."""
from pathlib import Path
import hashlib

ROOT = Path(__file__).resolve().parent
PROJECT = ROOT / 'MiAgenda.xcodeproj'
PROJECT.mkdir(exist_ok=True)
def ident(value):
    return hashlib.sha1(value.encode()).hexdigest().upper()[:24]
def quote(value):
    return '"' + value.replace('\\', '\\\\').replace('"', '\\"') + '"'
objects = []
def obj(name, body):
    objects.append(f'{ident(name)} = {{ {body} }};')

shared = [str(p.relative_to(ROOT)) for p in sorted((ROOT / 'Shared').glob('*.swift'))]
app = [str(p.relative_to(ROOT)) for p in sorted((ROOT / 'App').glob('*.swift'))]
widget = ['Widget/AgendaWidget.swift']
for path in shared + app + widget:
    obj('file' + path, f'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {quote(path)}; sourceTree = "<group>";')
for target, files in [('app', shared + app), ('widget', shared + widget)]:
    for path in files:
        obj(target + path, f'isa = PBXBuildFile; fileRef = {ident("file" + path)};')
for target, name, filetype in [('app', 'MiAgenda.app', 'wrapper.application'), ('widget', 'MiAgendaWidget.appex', 'wrapper.app-extension')]:
    obj(target + 'Product', f'isa = PBXFileReference; explicitFileType = {quote(filetype)}; path = {name}; sourceTree = BUILT_PRODUCTS_DIR;')
obj('embedWidget', f'isa = PBXBuildFile; fileRef = {ident("widgetProduct")}; settings = {{ ATTRIBUTES = (RemoveHeadersOnCopy, ); }};')
obj('sourcesGroup', 'isa = PBXGroup; children = (' + ', '.join(ident('file' + p) for p in shared + app + widget) + '); sourceTree = "<group>";')
obj('productsGroup', f'isa = PBXGroup; children = ({ident("appProduct")}, {ident("widgetProduct")}); name = Products; sourceTree = "<group>";')
obj('rootGroup', f'isa = PBXGroup; children = ({ident("sourcesGroup")}, {ident("productsGroup")}); sourceTree = "<group>";')
for target, files in [('app', shared + app), ('widget', shared + widget)]:
    obj(target + 'Sources', 'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (' + ', '.join(ident(target + f) for f in files) + '); runOnlyForDeploymentPostprocessing = 0;')
    for phase in ['Frameworks', 'Resources']:
        obj(target + phase, f'isa = PBX{phase}BuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;')
obj('appEmbed', f'isa = PBXCopyFilesBuildPhase; buildActionMask = 2147483647; dstPath = ""; dstSubfolderSpec = 13; files = ({ident("embedWidget")}); name = "Embed App Extensions"; runOnlyForDeploymentPostprocessing = 0;')
obj('proxy', f'isa = PBXContainerItemProxy; containerPortal = {ident("project")}; proxyType = 1; remoteGlobalIDString = {ident("widgetTarget")}; remoteInfo = MiAgendaWidget;')
obj('dependency', f'isa = PBXTargetDependency; target = {ident("widgetTarget")}; targetProxy = {ident("proxy")};')
for target, name, product in [('app', 'MiAgenda', 'application'), ('widget', 'MiAgendaWidget', 'app-extension')]:
    phases = [ident(target + p) for p in ['Sources', 'Frameworks', 'Resources']]
    if target == 'app':
        phases.append(ident('appEmbed'))
    dependency = ident('dependency') if target == 'app' else ''
    obj(target + 'Target', f'isa = PBXNativeTarget; buildConfigurationList = {ident(target + "ConfigList")}; buildPhases = ({", ".join(phases)}); buildRules = (); dependencies = ({dependency}); name = {name}; productName = {name}; productReference = {ident(target + "Product")}; productType = "com.apple.product-type.{product}";')
common = dict(ALWAYS_SEARCH_USER_PATHS='NO', CLANG_ENABLE_MODULES='YES', CLANG_ENABLE_OBJC_ARC='YES', IPHONEOS_DEPLOYMENT_TARGET='26.0', SDKROOT='iphoneos', SWIFT_VERSION='5.0', TARGETED_DEVICE_FAMILY='1', CODE_SIGN_STYLE='Automatic', ENABLE_USER_SCRIPT_SANDBOXING='YES')
for group in ['project', 'app', 'widget']:
    for mode in ['Debug', 'Release']:
        settings = dict(common, SWIFT_OPTIMIZATION_LEVEL='-Onone' if mode == 'Debug' else '-O', DEBUG_INFORMATION_FORMAT='dwarf' if mode == 'Debug' else 'dwarf-with-dsym')
        if mode == 'Debug':
            settings['SWIFT_ACTIVE_COMPILATION_CONDITIONS'] = 'DEBUG'
        if group != 'project':
            settings.update(PRODUCT_NAME='$(TARGET_NAME)', PRODUCT_BUNDLE_IDENTIFIER='com.alvarousabiaga.agenda.personal' + ('.widget' if group == 'widget' else ''), INFOPLIST_FILE=('Widget' if group == 'widget' else 'App') + '/Info.plist', GENERATE_INFOPLIST_FILE='NO', CURRENT_PROJECT_VERSION='2', MARKETING_VERSION='0.2.0', LD_RUNPATH_SEARCH_PATHS='$(inherited) @executable_path/Frameworks' + (' @executable_path/../../Frameworks' if group == 'widget' else ''))
        if group == 'widget':
            settings.update(APPLICATION_EXTENSION_API_ONLY='YES', SKIP_INSTALL='YES')
        obj(group + mode, 'isa = XCBuildConfiguration; buildSettings = {' + ' '.join(f'{k} = {quote(v)};' for k, v in settings.items()) + '}; name = ' + mode + ';')
    obj(group + 'ConfigList', f'isa = XCConfigurationList; buildConfigurations = ({ident(group + "Debug")}, {ident(group + "Release")}); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
obj('project', f'isa = PBXProject; attributes = {{ BuildIndependentTargetsInParallel = YES; LastUpgradeCheck = 2600; }}; buildConfigurationList = {ident("projectConfigList")}; compatibilityVersion = "Xcode 14.0"; developmentRegion = es; hasScannedForEncodings = 0; knownRegions = (es, en, Base); mainGroup = {ident("rootGroup")}; productRefGroup = {ident("productsGroup")}; projectDirPath = ""; projectRoot = ""; targets = ({ident("appTarget")}, {ident("widgetTarget")});')
(PROJECT / 'project.pbxproj').write_text('// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n' + '\n'.join(objects) + '\n}; rootObject = ' + ident('project') + '; }\n')
schemes = PROJECT / 'xcshareddata' / 'xcschemes'
schemes.mkdir(parents=True, exist_ok=True)
reference = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ident("appTarget")}" BuildableName="MiAgenda.app" BlueprintName="MiAgenda" ReferencedContainer="container:MiAgenda.xcodeproj"/>'
(schemes / 'MiAgenda.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2600" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{reference}</BuildActionEntry></BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug"/>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{reference}</BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"/>
<AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>''')
print(f'Generated Xcode project: {len(objects)} objects')
