import json
import torch
from PIL import Image
from torchvision import transforms
from data import build_insect_loaders


def test_full_image_resize_preserves_edges_and_eval_pipeline(tmp_path):
    for split in ('train', 'val', 'test'):
        for label in ('a', 'b'):
            folder=tmp_path/split/label
            folder.mkdir(parents=True)
            image=Image.new('RGB',(64,32),'black')
            for x in list(range(8))+list(range(56,64)):
                for y in range(32): image.putpixel((x,y),(255,0,0))
            image.save(folder/'sample.png')
    stats=tmp_path/'stats.json'
    stats.write_text(json.dumps({'mean':[0,0,0],'std':[1,1,1]}))
    default=build_insect_loaders(tmp_path,stats,2,0,False)
    resized=build_insect_loaders(tmp_path,stats,2,0,False,train_resize=True)
    assert isinstance(default.train_loader.dataset.transform.transforms[0],transforms.RandomResizedCrop)
    assert isinstance(resized.train_loader.dataset.transform.transforms[0],transforms.Resize)
    image=Image.open(tmp_path/'train/a/sample.png')
    output=resized.train_loader.dataset.transform.transforms[0](image)
    assert output.getpixel((0,16))==(255,0,0)
    assert output.getpixel((31,16))==(255,0,0)
    assert torch.equal(default.val_loader.dataset[0][0],resized.val_loader.dataset[0][0])
    assert next(iter(resized.train_loader))[0].shape==(2,3,32,32)
