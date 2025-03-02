import std.conv : to;
import std.file;
import std.path;
import std.string;

import workspaced.api;
import workspaced.com.dub;

void main()
{
	string dir = buildNormalizedPath(getcwd, "..", "tc_fsworkspace");
	scope backend = new WorkspaceD();
	auto instance = backend.addInstance(dir);
	backend.register!DubComponent;

	auto dub = backend.get!DubComponent(dir);

	dub.upgrade();
	assert(dub.dependencies.length > 2);
	assert(dub.rootDependencies == ["serve-d:workspace-d"]);
	// this can be
	// tc_fsworkspace/source, workspace-d/source
	// if no dependencies are fetched
	// or with all dependencies there a lot more
	assert(dub.imports.length >= 2, dub.imports.to!string);
	assert(dub.stringImports[0].endsWith("views")
			|| dub.stringImports[0].endsWith("views/") || dub.stringImports[0].endsWith("views\\"));
	assert(dub.fileImports.length > 10);
	assert(dub.configurations.length == 2);
	assert(dub.buildTypes.length);
	assert(dub.configuration == "application");
	assert(dub.archTypes.length);
	assert(!dub.archType.length); // compiler default (null) has been default since serve-d 0.8.0
	assert(dub.buildType == "debug");
	assert(dub.compiler.length);
	assert(dub.name == "test-fsworkspace");
	assert(dub.path.toString.endsWith("tc_fsworkspace")
			|| dub.path.toString.endsWith("tc_fsworkspace/")
			|| dub.path.toString.endsWith("tc_fsworkspace\\"));
	if (dub.canBuild)
		assert(dub.build.getBlocking.count!(a => a.type == ErrorType.Warning || a.type == ErrorType.Error) == 0);
}
