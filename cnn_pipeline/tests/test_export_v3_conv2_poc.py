"""Independent transport/order and software Pool1 tests; no real dataset."""
import pytest
import torch
from export_v3_conv2_poc import tile_major_words, pool1_fixture, export


def test_tile_major_two_planes_multiple_positions_and_c7_c8():
    x = torch.tensor([[[c*5+h*2+w-64 for w in range(2)] for h in range(2)] for c in range(16)],dtype=torch.int8)
    before=x.clone(); words=tile_major_words(x)
    assert len(words)==8
    for t in range(2):
        for h in range(2):
            for w in range(2):
                word=words[t*4+h*2+w]
                for lane in range(8):
                    byte=(word>>(8*lane))&255
                    assert byte==((t*8+lane)*5+h*2+w-64)&255
    assert (words[0]>>56)&255 == (-29)&255  # c7, h0,w0
    assert words[4]&255 == (-24)&255        # c8, h0,w0; new plane, not adjacent beat
    assert torch.equal(x,before)
    assert words==tile_major_words(x)


@pytest.mark.parametrize('x',[
    torch.zeros(16,2,2),torch.zeros(16,2,2,dtype=torch.int64),
    torch.zeros(1,16,2,2,dtype=torch.int8),torch.zeros(15,2,2,dtype=torch.int8),
    torch.zeros(16,0,2,dtype=torch.int8),torch.zeros(0,2,2,dtype=torch.int8),
])
def test_reject_wrong_transport_tensor(x):
    with pytest.raises(ValueError): tile_major_words(x)


def test_signed_transport_extremes():
    x=torch.tensor([-128,-127,-1,0,1,2,126,127],dtype=torch.int8).reshape(8,1,1)
    assert tile_major_words(x)==[0x7F7E020100FF8180]


def test_pool1_reuses_integer_path_and_preserves_channel_order():
    image=torch.zeros(3,4,4)
    weights=torch.zeros(16,3,3,3,dtype=torch.int8)
    p={'s_x':1.,'bias_q':list(range(16)),'M0':[65536]*16,'n':[16]*16}
    result=pool1_fixture(image,p,weights)
    assert result.shape==(1,16,2,2) and result.dtype==torch.int8
    assert result.tolist()==[[[[c,c],[c,c]] for c in range(16)]]
    assert not image.any() and not weights.any()
    assert p['bias_q']==list(range(16))


def test_refuse_existing_output(tmp_path):
    sentinel=tmp_path/'sentinel';sentinel.write_text('preserve')
    with pytest.raises(FileExistsError): export(tmp_path/'missing',tmp_path)
    assert sentinel.read_text()=='preserve'
