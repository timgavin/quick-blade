@extends('layouts.app')

@section('title', 'Welcome')

@push('styles')
    <link rel="stylesheet" href="/css/welcome.css">
@endpush

@section('content')
    <div class="container">
        <h1>{{ $title }}</h1>
        <p>Welcome to {{ config('app.name') }}!</p>

        @if($showFeatures)
            <section class="features">
                <h2>Features</h2>

                @foreach($features as $feature)
                    <div class="feature-card">
                        <h3>{{ $feature->name }}</h3>
                        <p>{{ $feature->description }}</p>
                    </div>
                @endforeach
            </section>
        @endif

        @include('partials.footer')
    </div>
@endsection

@push('scripts')
    <script src="/js/welcome.js"></script>
@endpush
