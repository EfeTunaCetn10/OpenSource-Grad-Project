"""Three-plane ordering and software Pool2 fixture tests, without datasets."""
import pytest
import torch
from export_v3_conv3_poc import pool2_fixture, tile_major_words, export


@pytest.mark.parametrize('h,w',[(1,1),(8,8),(3,5)])
def test_three_plane_transport_and_both_boundaries(h,w):
    x=torch.tensor([[[(c*29+y*17+z*7)%256-128 for z in range(w)] for y in range(h)] for c in range(24)],dtype=torch.int8)
    before=x.clone();words=tile_major_words(x)
    assert len(words)==3*h*w
    for c in range(24):
        for y in range(h):
            for z in range(w):
                byte=(words[(c//8)*h*w+y*w+z]>>(8*(c%8)))&255
                assert byte==((c*29+y*17+z*7)%256-128)&255
    for c in (7,8,15,16):
        assert ((words[(c//8)*h*w]>>(8*(c%8)))&255)==int(x[c,0,0])&255
    assert torch.equal(x,before)
    assert words==tile_major_words(x)


def test_pool2_fixture_manual_constant_channels():
    image=torch.zeros(3,8,8)
    w1=torch.zeros(16,3,3,3,dtype=torch.int8)
    w2=torch.zeros(24,16,3,3,dtype=torch.int8)
    p1={'s_x':1.,'bias_q':list(range(16)),'M0':[65536]*16,'n':[16]*16}
    p2={'bias_q':list(range(-4,20)),'M0':[65536]*24,'n':[16]*24}
    result=pool2_fixture(image,p1,w1,p2,w2)
    assert result.shape==(1,24,2,2) and result.dtype==torch.int8
    assert result.tolist()==[[[[max(0,c-4)]*2 for _ in range(2)] for c in range(24)]]
    assert not image.any() and not w1.any() and not w2.any()
    assert p2['bias_q']==list(range(-4,20))


def test_no_overwrite(tmp_path):
    sentinel=tmp_path/'sentinel';sentinel.write_text('preserve')
    with pytest.raises(FileExistsError): export(tmp_path/'missing',tmp_path)
    assert sentinel.read_text()=='preserve'
