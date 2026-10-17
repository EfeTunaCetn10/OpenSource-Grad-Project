import pytest
import torch
from export_v3_pool_poc import pool_chw, export
from export_v3_conv2_poc import tile_major_words


@pytest.mark.parametrize('position',[0,1,2,3])
def test_each_position_can_be_negative_max(position):
    values=[-128,-100,-90,-80];values[position]=-1
    x=torch.tensor(values,dtype=torch.int8).reshape(1,2,2)
    before=x.clone()
    assert pool_chw(x).tolist()==[[[-1]]]
    assert torch.equal(x,before)


@pytest.mark.parametrize('values,answer',[
    ([-128]*4,-128),([127]*4,127),([-17]*4,-17),([-128,0,127,-1],127)])
def test_ties_extremes_signed(values,answer):
    assert pool_chw(torch.tensor(values,dtype=torch.int8).reshape(1,2,2)).item()==answer


def test_channel_and_spatial_order():
    x=torch.tensor([[[c-32+h*2+w for w in range(6)] for h in range(4)] for c in range(24)],dtype=torch.int8)
    y=pool_chw(x)
    assert y.shape==(24,2,3)
    for c in range(24):
        for h in range(2):
            for w in range(3): assert y[c,h,w].item()==c-29+4*h+2*w
    words=tile_major_words(y)
    for c in (7,8,15,16): assert ((words[(c//8)*6]>>(8*(c%8)))&255)==(c-29)&255


@pytest.mark.parametrize('shape',[(8,1,2),(8,3,4),(8,4,3)])
def test_reject_invalid_pool_shape(shape):
    with pytest.raises(ValueError):pool_chw(torch.zeros(shape,dtype=torch.int8))


def test_no_overwrite(tmp_path):
    with pytest.raises(FileExistsError):export(tmp_path/'absent',tmp_path)


def test_fc_pool3_order_exhaustive_one_hot():
    from export_v3_pool_poc import pool3_flatten_indices
    order=pool3_flatten_indices()
    assert sorted(order)==list(range(512))
    # For every one-hot input, the selected weight column must be the CHW
    # coordinate, including both sides of every channel-tile boundary.
    for physical in range(512):
        tile,pixel_lane=divmod(physical,128)
        pixel,lane=divmod(pixel_lane,8)
        h,w=divmod(pixel,4)
        c=tile*8+lane
        assert order[physical]==c*16+h*4+w
    assert order[:9]==[0,16,32,48,64,80,96,112,1]
    assert order[127:130]==[127,128,144]
    # Independent integer dot-product equality with asymmetric signed data.
    x=torch.tensor([(i*11)%251-125 for i in range(512)],dtype=torch.int8)
    w=torch.tensor([(i*7)%253-126 for i in range(512)],dtype=torch.int8)
    physical_w=w[order];physical_x=x[order]
    assert sum(int(a)*int(b) for a,b in zip(x,w))==sum(int(a)*int(b) for a,b in zip(physical_x,physical_w))


def fc_fixture(tmp_path,monkeypatch):
    import json
    import export_v3_pool_poc as module
    from calibration import sha256
    ptq=tmp_path/'ptq';ptq.mkdir();pool=tmp_path/'pool';pool.mkdir()
    q={'checkpoint':{'sha256':'synthetic'},'activation_scales':{'features.7':1.,'classifier.2':1.,'classifier.3':1.},'layers':[{}, {}, {}]}
    weights={}
    for name,shape,ik,ok,relu in [('classifier.1',[64,512],'features.7','classifier.2',True),('classifier.3',[10,64],'classifier.2','classifier.3',False)]:
        q['layers'].append({'name':name,'shape':shape,'kind':'linear','input_key':ik,'output_key':ok,'relu':relu,
            's_x':1.,'s_y':1.,'bias_q':list(range(-shape[0],0)),'M0':[65536]*shape[0],'n':[16]*shape[0]})
        weights[name+'.weight']=torch.zeros(shape,dtype=torch.int8)
    torch.save(weights,ptq/'weights_int8.pt')
    path=pool/'pool3_expected.mem';path.write_text('0000000000000000\n'*64)
    m={'checkpoint':q['checkpoint'],'sample':{},'source_identity_sha256':{},
       'files':{path.name:sha256(path)},'stages':[{}, {}, {'output_shape':[32,4,4],'output_scale':1.}]}
    (pool/'manifest.json').write_text(json.dumps(m))
    monkeypatch.setattr(module,'verified_inputs',lambda _: (q,None,None,None,{},{}))
    return ptq,pool,tmp_path/'out',q


def test_fc_export_tail_signed_logits_and_no_overwrite(tmp_path,monkeypatch):
    from export_v3_pool_poc import export_fc
    from calibration import sha256
    ptq,pool,out,q=fc_fixture(tmp_path,monkeypatch)
    before={p:sha256(p) for d in (ptq,pool) for p in d.iterdir()}
    report=export_fc(ptq,pool,out)
    assert report['stages']==[
        {'name':'FC1','outputs':64,'K':512,'relu':True,'final_tile_active_outputs':8},
        {'name':'FC2','outputs':10,'K':64,'relu':False,'final_tile_active_outputs':2}]
    assert int((out/'fc1/t0_y.mem').read_text(),16)==0
    assert int((out/'fc2/t1_y.mem').read_text(),16)==0xFFFE
    assert len((out/'fc1/wbank0.mem').read_text().split())==4096
    assert (out/'fc2/wbank2.mem').read_text().split()[64:]==['00']*64
    assert all(sha256(p)==digest for p,digest in before.items())
    assert all(sha256(out/name)==digest for name,digest in report['files'].items())
    with pytest.raises(FileExistsError):export_fc(ptq,pool,out)


@pytest.mark.parametrize('fault',['identity','hash','shape','scale','layer'])
def test_fc_export_rejects_bad_provenance_or_topology(tmp_path,monkeypatch,fault):
    import json
    from export_v3_pool_poc import export_fc
    ptq,pool,out,q=fc_fixture(tmp_path,monkeypatch)
    p=pool/'manifest.json';m=json.loads(p.read_text())
    if fault=='identity':m['checkpoint']={}
    elif fault=='hash':m['files']['pool3_expected.mem']='bad'
    elif fault=='shape':m['stages'][2]['output_shape']=[16,4,4]
    elif fault=='scale':m['stages'][2]['output_scale']=2.
    else:q['layers'][3]['relu']=False
    p.write_text(json.dumps(m))
    with pytest.raises(ValueError):export_fc(ptq,pool,out)
    assert not out.exists()


def test_fc_export_actual_weight_columns_and_pool3_one_hot(tmp_path,monkeypatch):
    import json
    from calibration import sha256
    from export_v3_pool_poc import export_fc
    ptq,pool,out,q=fc_fixture(tmp_path,monkeypatch)
    weights=torch.load(ptq/'weights_int8.pt',weights_only=True)
    w=((torch.arange(64*512).reshape(64,512)*13+7)%255-127).to(torch.int8)
    weights['classifier.1.weight']=w
    torch.save(weights,ptq/'weights_int8.pt')
    # c=8,h=0,w=0 is canonical index 128 and physical byte 128.
    # c=7,h=3,w=3 is canonical index 127 and physical byte 127.
    words=[0]*64;words[15]=1<<56;words[16]=1
    p=pool/'pool3_expected.mem';p.write_text(''.join(f'{v:016X}\n' for v in words))
    m=json.loads((pool/'manifest.json').read_text());m['files'][p.name]=sha256(p)
    (pool/'manifest.json').write_text(json.dumps(m))
    export_fc(ptq,pool,out)
    for bank in range(8):
        values=[int(v,16) for v in (out/f'fc1/wbank{bank}.mem').read_text().split()]
        for tile in range(8):
            for physical in range(512):
                ct,rem=divmod(physical,128);pixel,lane=divmod(rem,8)
                h,col=divmod(pixel,4);canonical=(ct*8+lane)*16+h*4+col
                assert values[tile*512+physical]==int(w[tile*8+bank,canonical])&255
    for tile in range(8):
        mac=[int(v,16) for v in (out/f'fc1/t{tile}_acc.mem').read_text().split()]
        assert mac==[(int(w[c,127])+int(w[c,128]))&0xffffffff for c in range(tile*8,tile*8+8)]
