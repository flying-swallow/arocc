// Verify Bazel runtime data lookup from either a runfiles tree or manifest.
// Both the fixture path and the unrelated working directory contain spaces.
module runfiles_portability;
import std::io, std::io::path, std::os::env, std::core::dstring, std::core::string;

const String FIXTURE_REL = "test/migration/runfiles fixtures/portable data.txt";
const String FIXTURE_CONTENT = "runfiles lookup survives a changed working directory\n";

fn String absolute_from(String value, String original_cwd)
{
	if (value.is_absolute_path()!!) return value.copy(tmem);
	return string::format(tmem, "%s/%s", original_cwd, value);
}

fn String decode_manifest_field(String field)
{
	DString decoded;
	decoded.tinit();
	for (usz i = 0; i < field.len; i++)
	{
		if (field[i] == '\\' && i + 1 < field.len)
		{
			i++;
			switch (field[i])
			{
				case 's': decoded.append(' ');
				case 'b': decoded.append('\\');
				case 'n': decoded.append('\n');
				default:
					decoded.append('\\');
					decoded.append(field[i]);
			}
		}
		else
		{
			decoded.append(field[i]);
		}
	}
	return decoded.str_view();
}

fn String fixture_from_manifest(String manifest_path, String workspace)
{
	char[]? manifest_data = file::load(tmem, manifest_path);
	assert(@ok(manifest_data), "could not read runfiles manifest '%s'", manifest_path);
	String contents = (String)manifest_data!!;
	DString expected_key;
	expected_key.tinit();
	expected_key.append(workspace);
	expected_key.append('/');
	expected_key.append(FIXTURE_REL);
	String key = expected_key.str_view();
	bool found = false;

	usz start = 0;
	while (start < contents.len)
	{
		usz end = start;
		while (end < contents.len && contents[end] != '\n') end++;
		String line = end > start ? contents[start..end - 1] : "";
		if (line.len && line[0] == '\\') line = line[1..];
		usz separator = 0;
		while (separator < line.len && line[separator] != ' ') separator++;
		if (separator < line.len)
		{
			String manifest_key = decode_manifest_field(line[0..separator - 1]);
			if (manifest_key == key)
			{
				found = true;
				return decode_manifest_field(line[separator + 1..]);
			}
		}
		start = end + 1;
	}
	assert(found, "runfiles manifest '%s' has no entry for '%s'", manifest_path, key);
	return "";
}

fn String fixture_path(String runfiles_root, String manifest_path, String workspace)
{
	if (runfiles_root.len)
	{
		String tree_path = string::format(tmem, "%s/%s/%s", runfiles_root, workspace, FIXTURE_REL);
		if (file::is_file(tree_path)) return tree_path;
	}
	assert(manifest_path.len, "neither the runfiles tree nor RUNFILES_MANIFEST_FILE is available");
	return fixture_from_manifest(manifest_path, workspace);
}

fn void runfiles_data_is_readable_from_space_named_cwd() @test
{
	String original_cwd = (String)path::cwd(tmem)!!;
	String? workspace_opt = env::get_var(tmem, "TEST_WORKSPACE");
	assert(@ok(workspace_opt), "TEST_WORKSPACE is required for this Bazel runfiles integration test");
	String workspace = workspace_opt!!;
	String? root_opt = env::get_var(tmem, "TEST_SRCDIR");
	String? manifest_opt = env::get_var(tmem, "RUNFILES_MANIFEST_FILE");
	String root = @ok(root_opt) ? absolute_from(root_opt!!, original_cwd) : "";
	String manifest = @ok(manifest_opt) ? absolute_from(manifest_opt!!, original_cwd) : "";

	String? tmp_opt = env::get_var(tmem, "TEST_TMPDIR");
	String tmp = @ok(tmp_opt) ? absolute_from(tmp_opt!!, original_cwd) : (String)path::temp_directory(tmem)!!;
	String unrelated_cwd = string::format(tmem, "%s/runfiles cwd with spaces", tmp);
	(void)path::mkdir(unrelated_cwd, true)!!;
	(void)path::chdir(unrelated_cwd)!!;

	// Resolve and read only after changing the process CWD. The absolute
	// metadata paths keep the lookup independent of the original directory.
	String fixture = fixture_path(root, manifest, workspace);
	char[]? fixture_data = file::load(tmem, fixture);
	String contents = @ok(fixture_data) ? (String)fixture_data!! : "";
	String manifest_fixture = manifest.len ? fixture_from_manifest(manifest, workspace) : fixture;
	char[]? manifest_data = file::load(tmem, manifest_fixture);
	String manifest_contents = @ok(manifest_data) ? (String)manifest_data!! : "";
	(void)path::chdir(original_cwd)!!;
	assert(@ok(fixture_data), "runfiles fixture not found at '%s'", fixture);
	assert(contents == FIXTURE_CONTENT, "unexpected runfiles fixture contents: '%s'", contents);
	assert(@ok(manifest_data), "runfiles manifest resolved missing fixture at '%s'", manifest_fixture);
	assert(manifest_contents == FIXTURE_CONTENT, "manifest resolved different fixture contents");
}
