@extends('layouts.app')

@section('content')
    <div class="form-container">
        <h1>Edit Profile</h1>

        <form action="{{ route('profile.update') }}" method="POST" enctype="multipart/form-data">
            @csrf
            @method('PUT')

            <div class="form-group">
                <label for="name">Name</label>
                <input
                    type="text"
                    id="name"
                    name="name"
                    value="{{ old('name', $user->name) }}"
                    class="form-control @error('name') is-invalid @enderror"
                >
                @error('name')
                    <div class="invalid-feedback">{{ $message }}</div>
                @enderror
            </div>

            <div class="form-group">
                <label for="email">Email</label>
                <input
                    type="email"
                    id="email"
                    name="email"
                    value="{{ old('email', $user->email) }}"
                    class="form-control @error('email') is-invalid @enderror"
                >
                @error('email')
                    <div class="invalid-feedback">{{ $message }}</div>
                @enderror
            </div>

            <div class="form-group">
                <label for="bio">Bio</label>
                <textarea
                    id="bio"
                    name="bio"
                    rows="4"
                    class="form-control @error('bio') is-invalid @enderror"
                >{{ old('bio', $user->bio) }}</textarea>
                @error('bio')
                    <div class="invalid-feedback">{{ $message }}</div>
                @enderror
            </div>

            <div class="form-group">
                <label for="avatar">Avatar</label>
                <input type="file" id="avatar" name="avatar" class="form-control">
                @if($user->avatar)
                    <img src="{{ asset('storage/' . $user->avatar) }}" alt="Current avatar" class="mt-2" width="80">
                @endif
            </div>

            <div class="form-actions">
                <button type="submit" class="btn btn-primary">Save Changes</button>
                <a href="{{ route('profile.show') }}" class="btn btn-secondary">Cancel</a>
            </div>
        </form>
    </div>
@endsection
