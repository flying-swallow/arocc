module build_smoke @test;
import aro;

fn void version_is_set()
{
	assert(aro::VERSION.len > 0);
}
