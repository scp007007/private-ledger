import csv
import io
import pytest

from app.importers import BillImportError, parse_bill
from test_api import api, HEADER


def fixture(**overrides):
    row = dict(zip(['ID','时间','账本','分类','二级分类','类型','金额','币种','账户1','备注','标签'],
        ['fixture-001','2026-10-01 12:00:00','Synthetic book','Food','Lunch','Spend','12.34','CNY','PRIVATE_ACCOUNT','Synthetic note','tag']))
    row.update(overrides)
    text = io.StringIO(newline='')
    writer = csv.DictWriter(text, fieldnames=row.keys())
    writer.writeheader()
    writer.writerow(row)
    return text.getvalue().encode('utf-8-sig')


def test_qianji_preserves_accounting_and_stable_id_without_private_extra_columns():
    data = fixture()
    row = parse_bill('generic','fixture.csv',data)[0]
    assert row['direction'] == 'expense'
    assert row['amount_cents'] == 1234
    assert row['external_id'] == 'qianji:fixture-001'
    assert row['category'] == 'Food / Lunch'
    assert row['note'] == 'Synthetic note'
    assert row['tags'] == ['tag']
    assert 'PRIVATE_ACCOUNT' not in str(row)
    assert row['dedupe_key'] == parse_bill('generic','renamed.csv',data)[0]['dedupe_key']
    assert parse_bill('generic','fixture.csv',fixture(类型='Income'))[0]['direction'] == 'income'


@pytest.mark.parametrize('overrides', [{'类型':'Transfer'}, {'币种':'USD'}, {'ID':''}, {'手续费':'2'}, {'关联账单':'private-id'}])
def test_unsupported_semantics_fail_instead_of_silent_conversion(overrides):
    with pytest.raises(BillImportError):
        parse_bill('generic','fixture.csv',fixture(**overrides))


@pytest.mark.parametrize('source', ['wechat','alipay'])
def test_qianji_requires_generic_source(source):
    with pytest.raises(BillImportError, match='标准 CSV'):
        parse_bill(source,'fixture.csv',fixture())


def test_qianji_preview_commit_and_reimport_deduplicate(api):
    client, _ = api
    def preview():
        r = client.post('/api/v1/imports/preview', headers=HEADER,
            data={'source':'generic'}, files={'file':('fixture.csv',fixture(),'text/csv')})
        assert r.status_code == 200
        return r.json()
    draft = preview()
    assert draft['new_count'] == 1
    result = client.post(f"/api/v1/imports/{draft['preview_id']}/commit",headers=HEADER)
    assert result.json()['imported'] == 1
    assert preview()['duplicate_count'] == 1
